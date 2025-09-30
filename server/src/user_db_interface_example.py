"""
Sample client for server/src/user_db_interface.ts

Dependencies:
    pip install pandas requests

This script calls the Express GET /query endpoint exposed by user_db_interface.ts
and reproduces the intent of the SQL example:
  - Filter by subjects (momo, riker), state_system (planko), date range
  - Keep rows with status >= 0
  - Select and display key columns
  - Extract trialinfo.stiminfo JSON, flatten into columns
  - Sort by server_trial_id descending and limit to 100

Note:
  - Configure DB_USER/DB_PASS to a NON-forbidden user (not: postgres, lab, sym_user)
  - Ensure the Node server is running: http://<host>:3001/query
"""

from __future__ import annotations

import os
import json
from typing import Any, Dict, List, Optional
from datetime import datetime, timedelta, date

import pandas as pd
import requests


# ----------------------
# Configuration
# ----------------------
BASE_URL = os.environ.get("HB_QUERY_URL", "http://10.2.145.85:3001/query")

# Provide valid credentials for the Postgres user that the server will use to connect
# IMPORTANT: The server forbids 'postgres', 'lab', and 'sym_user'. Use a readonly/reporting user.
DB_USER = os.environ.get("HB_DB_USER", "sheinberglab_analysis")
DB_PASS = os.environ.get("HB_DB_PASS", "mario!")

# Query parameters to reproduce the SQL
TABLE = os.environ.get("HB_TABLE", "server_trial")
START_DATE = os.environ.get("HB_START_DATE", "2025-08-01")
END_DATE = os.environ.get("HB_END_DATE", "2025-09-01")
SUBJECTS = os.environ.get("HB_SUBJECTS", "momo,riker")  # comma-separated for multi-value
STATE_SYSTEM = os.environ.get("HB_STATE_SYSTEM", "planko")


def _ensure_dict(value: Any) -> Dict[str, Any]:
    """Coerce arbitrary input into a dict (best-effort)."""
    if isinstance(value, dict):
        return value
    if value is None or (isinstance(value, float) and pd.isna(value)):
        return {}
    if isinstance(value, (bytes, bytearray)):
        try:
            value = value.decode("utf-8", errors="ignore")
        except Exception:
            return {}
    if isinstance(value, str):
        text = value.strip()
        if text == "":
            return {}
        try:
            return json.loads(text)
        except Exception:
            return {}
    return {}


class TooLargeError(Exception):
    pass


def _parse_date(value: str) -> date:
    return datetime.strptime(value, "%Y-%m-%d").date()


def _format_ts(d: datetime) -> str:
    # Postgres accepts 'YYYY-MM-DD HH:MM:SS' strings
    return d.strftime("%Y-%m-%d %H:%M:%S")


def _fetch_rows_window(start_ts: str, end_ts: str, extra: Optional[Dict[str, str]] = None) -> List[Dict[str, Any]]:
    params = {
        "user": DB_USER,
        "pass": DB_PASS,
        "table": TABLE,
        "start_date": start_ts,
        "end_date": end_ts,
        "subject": SUBJECTS,
        "state_system": STATE_SYSTEM,
    }
    if extra:
        params.update(extra)

    resp = requests.get(BASE_URL, params=params, timeout=180)
    if resp.status_code == 200:
        data = resp.json()
        if not isinstance(data, list):
            raise SystemExit(f"Unexpected response format: {type(data)}")
        return data

    # Inspect error body
    body_text = resp.text
    try:
        body_json = resp.json()
    except Exception:
        body_json = {"raw": body_text}

    joined = json.dumps(body_json)
    if resp.status_code == 413 or "exceeds 100MB" in joined or "Invalid string length" in joined:
        raise TooLargeError(joined)
    raise SystemExit(f"HTTP {resp.status_code}: {body_json}")


def fetch_all_rows_chunked() -> List[Dict[str, Any]]:
    start_date = _parse_date(START_DATE)
    end_date = _parse_date(END_DATE)

    window_days = max(1, int(os.environ.get("HB_WINDOW_DAYS", "7")))
    min_window_days = max(1, int(os.environ.get("HB_MIN_WINDOW_DAYS", "1")))

    all_rows: List[Dict[str, Any]] = []
    curr = start_date
    while curr < end_date:
        window_end = min(curr + timedelta(days=window_days), end_date)
        start_ts = f"{curr.isoformat()} 00:00:00"
        end_ts = f"{window_end.isoformat()} 00:00:00"
        try:
            part = _fetch_rows_window(start_ts, end_ts)
            all_rows.extend(part)
            curr = window_end
        except TooLargeError:
            if window_days > min_window_days:
                # Halve the window and retry
                window_days = max(min_window_days, window_days // 2)
                continue
            # Day window still too large; attempt sub-day splits
            if not _fetch_subday(curr, min(window_end, end_date), all_rows):
                raise SystemExit(
                    "A single-day window still exceeds limits; consider narrowing filters (subjects, project, protocol, variant)."
                )
            curr = window_end

    return all_rows


def _fetch_subday(day_start: date, day_end: date, sink: List[Dict[str, Any]]) -> bool:
    # Split within [day_start, day_end) into hourly windows, adaptively halving if needed
    start_dt = datetime.combine(day_start, datetime.min.time())
    end_dt = datetime.combine(day_end, datetime.min.time())
    step_hours = max(1, int(os.environ.get("HB_WINDOW_HOURS", "6")))
    min_hours = 1

    curr = start_dt
    while curr < end_dt:
        window_end = min(curr + timedelta(hours=step_hours), end_dt)
        try:
            part = _fetch_rows_window(_format_ts(curr), _format_ts(window_end))
            sink.extend(part)
            curr = window_end
        except TooLargeError:
            if step_hours > min_hours:
                step_hours = max(min_hours, step_hours // 2)
                continue
            return False
    return True


def main() -> None:
    rows = fetch_all_rows_chunked()
    print(f"Fetched {len(rows)} rows from endpoint (after chunking)")
    if not rows:
        return

    df = pd.DataFrame(rows)

    # Deduplicate if server_trial_id exists
    if "server_trial_id" in df.columns:
        before = len(df)
        df = df.drop_duplicates(subset=["server_trial_id"], keep="last")

    # Apply status >= 0 (if column present)
    if "status" in df.columns:
        df = df[df["status"] >= 0]

    # Extract trialinfo.stiminfo into its own dict column
    stim_col = None
    if "trialinfo" in df.columns:
        trialinfo_dicts = df["trialinfo"].apply(_ensure_dict)
        stim_col = trialinfo_dicts.apply(lambda d: _ensure_dict(d.get("stiminfo")))
    elif "stiminfo" in df.columns:
        stim_col = df["stiminfo"].apply(_ensure_dict)

    if stim_col is not None:
        stiminfo_flat = pd.json_normalize(stim_col)
        if not stiminfo_flat.empty:
            stiminfo_flat = stiminfo_flat.add_prefix("stiminfo.")
            df = df.join(stiminfo_flat)

    # Sort by server_trial_id desc if available, then take top 100
    if "server_trial_id" in df.columns:
        df = df.sort_values("server_trial_id", ascending=False)
    count_after_filter = len(df)
    df = df.head(100)

    # Select and order key columns if they exist
    preferred_cols = [
        "server_trial_id",
        "variant",
        "subject",
        "status",
        "rt",
        "trialinfo",
    ]
    existing_cols = [c for c in preferred_cols if c in df.columns]
    remaining_cols = [c for c in df.columns if c not in existing_cols]
    df = df[existing_cols + remaining_cols]

    if count_after_filter > 100:
        print(f"Showing {len(df)} rows (first 100 of {count_after_filter} after filtering)")
    else:
        print(f"Showing {len(df)} rows after filtering")
    if not df.empty:
        print(df.head(10))


if __name__ == "__main__":
    main()


