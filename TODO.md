\n### Milestones for migrating homebase comms (scoped to 192.168.4.201)

1) Bootstrap WS client (no DB writes yet)
   - Add a `HomebaseWS` manager in `server/src/index_ws.ts` that connects to `ws://192.168.4.201:2565/ws`.
   - Implement: exponential backoff + jitter, `eval`, `subscribe`/`unsubscribe`, `requestId` correlation, basic error forwarding.
   - Test: on startup, run `dservGet ess/status` and log the response; verify reconnect logs after manual server restart.

2) Wire subscriptions → console-log would-be DB upserts (preserve current mappings)
   - Subscribe to: `ess/status`, `ess/in_obs`, `ess/subject`, `ess/system`, `ess/protocol`, `ess/variant` (default `every=1`).
   - IMPORTANT: Do not write to DB from `index_ws.ts` (since `index.ts` is live). Instead, log structured messages indicating the exact upserts that would occur (table, keys, values, timestamps) using the same semantics as current `updateStatus`/`updateSubject`.
   - Test: start/stop ESS, change subject; confirm logs show correct would-be upserts while `index.ts` continues real writes and browser updates.

3) Initial sync + auto-resubscribe
   - On open/reconnect: re-establish all subs and run a small touch/init sequence to seed values (`dservTouch`/minimal `eval`).
   - Remove ping-triggered legacy refreshes in `index_ws.ts` (leave `index.ts` untouched).
   - Test: bounce the homebase; ensure values repopulate without manual refresh and subs are active.

4) Replace legacy forwarding paths (esscmd/gitcmd)
   - Route incoming browser commands through `HomebaseWS.eval()` (e.g., `ess::start`, `send git {...}`) and handle errors like `TCL_ERROR`.
   - Stop using `net.Socket` (2570/2573) in `index_ws.ts` only; do not touch `index.ts` yet.
   - Test: start/stop ESS and git ops from the UI and confirm DB/websocket behavior mirrors the old path.

5) Robustness + large payloads
   - Queue requests while reconnecting; cap in-flight per host; add jittered backoff caps.
   - Implement chunk reassembly (`isChunkedMessage`, `messageId`, `chunkIndex`, `totalChunks`) with size/time safety.
   - Optional: map large datapoints (e.g., `ess/stiminfo`) to DB if/when needed, reusing existing image paths.
   - Test: simulate network flap, high-frequency updates, and a large message; verify recovery and no crashes.

### Protocol notes from /reference_files (for future reference)

- Endpoint and transport
  - WebSocket server on homebase at `/ws`.
  - Example: `ws://<ip>:2565/ws`.

- JSON commands
  - `eval`: `{cmd:"eval", script:"...", requestId}` → response `{status:"ok"|"error", result|error, requestId}`.
  - `subscribe`: `{cmd:"subscribe", match:"pattern", every?}` → `{status:"ok", action:"subscribed", match}`; `every` default 1.
  - `unsubscribe`: `{cmd:"unsubscribe", match}` → `{status:"ok", action:"unsubscribed", match}`.
  - `touch`, `get`, `set` also available.
  - Git via eval: `send git {git::...}`.

- Datapoint messages
  - Pushes have `{type:"datapoint", name, timestamp, dtype, data}`; prefix `*` patterns supported.

- Large-message chunking
  - Use `isChunkedMessage`, `messageId`, `chunkIndex`, `totalChunks`, `data`, `isLastChunk` → reassemble then parse JSON.

- Initial sync pattern
  - On connect: set up subscriptions, then touch/init a minimal list to seed values.

- Reconnect
  - Auto-reconnect with backoff+jitter and auto-resubscribe.

- DB mapping semantics (log-only in index_ws.ts for now)
  - `ess/status` → `running` (1/0) and/or raw.
  - `ess/in_obs` → `in_obs` 0/1.
  - `ess/subject` → `animal`.
  - `ess/system`, `ess/protocol`, `ess/variant` → `variant` as `system:protocol:variant`.
  - Match `server_time` update behavior as in `index.ts`.

ONLY MODIFY server/src/index_ws.ts

### Homebase WebSocket integration — high-level tasks

- Define connection manager in `server/src/index_ws.ts`
  - Implement persistent WebSocket to `ws://<ip>:2565/ws` with exponential backoff, jitter, and auto-reconnect.
  - Auto-resubscribe on reconnect; default `every` to 1, allow override.
  - Correlate request/response via `requestId`; expose `eval`, `subscribe`, `unsubscribe`, `touch`, `get`, `set` helpers.
  - Handle chunked messages (`isChunkedMessage`, `messageId`, `chunkIndex`, `totalChunks`, `data`, `isLastChunk`).

- Subscription set and initial sync
  - Maintain subscriptions for: `ess/status`, `ess/in_obs`, `ess/subject`, `ess/system`, `ess/protocol`, `ess/variant` (and any minimal extras we already map to DB).
  - On connect, establish subscriptions and optionally run a small “touch”/initialize sequence to seed state.

- DB mapping (preserve existing schema/semantics)
  - Map incoming datapoints to `server_status` exactly as current logic does:
    - `ess/status` → `running` (1 for running, 0 for stopped).
    - `ess/in_obs` → `in_obs` (0/1 as-is).
    - `ess/system:ess/protocol:ess/variant` → `variant` string `system:protocol:variant`.
    - `ess/subject` → `animal`.
  - Upsert with timestamps as in current `updateStatus`/`updateSubject`.

- Replace legacy TCP flows
  - Remove usages of `sendToDS` and legacy ports (2570/2573) in favor of the new WS client API.
  - Keep browser WebSocket behavior unchanged.

- Device lifecycle and discovery
  - Bootstrap connections from `comm_status` addresses; watch for additions and start connections.
  - Retire connections when devices are removed/hidden.

- Error handling and client notifications
  - Surface command errors using existing `TCL_ERROR` websocket event to web clients.
  - Rate-limit noisy errors and large-broadcast datapoints if needed.

- Configuration
  - Allow per-topic `every` override; default to 1.
  - Future-proof for optional TLS (`wss://`) and auth headers (no-op for now).

- Observability
  - Log connection lifecycle, backoff attempts, subscription status, and large-message reassembly stats.

- Testing plan
  - Unit-test requestId correlation, chunk reassembly, and reconnection/resubscribe.
  - Integration-test against a homebase using `wscat`-equivalent flows.

- Migration wiring
  - Update `server/src/index.ts` to import and use the new connection manager for homebase communication paths.
  - Remove old ping-triggered `get_system_status`/`get_subject` refresh; rely on subscriptions.
