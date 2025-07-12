--
-- PostgreSQL database dump
--

-- Dumped from database version 17.4 (Debian 17.4-1.pgdg120+2)
-- Dumped by pg_dump version 17.4 (Ubuntu 17.4-1.pgdg24.04+2)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: pg_cron; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;


--
-- Name: EXTENSION pg_cron; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION pg_cron IS 'Job scheduler for PostgreSQL';


--
-- Name: pg_stat_statements; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_stat_statements WITH SCHEMA public;


--
-- Name: EXTENSION pg_stat_statements; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION pg_stat_statements IS 'track planning and execution statistics of all SQL statements executed';


--
-- Name: postgres_fdw; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS postgres_fdw WITH SCHEMA public;


--
-- Name: EXTENSION postgres_fdw; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION postgres_fdw IS 'foreign-data wrapper for remote PostgreSQL servers';


--
-- Name: copy_recent_stats_to_server(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.copy_recent_stats_to_server() RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    INSERT INTO server_recent_stats (
        status_type, host, subject, project, state_system,
        protocol, variant, aborts, pc, rt, trials, last_updated
    )
    SELECT 
        status_type, host, subject, project, state_system,
        protocol, variant, aborts, pc, rt, trials, last_updated
    FROM recent_stats;
END;
$$;


ALTER FUNCTION public.copy_recent_stats_to_server() OWNER TO postgres;

--
-- Name: copy_status_to_server(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.copy_status_to_server() RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    INSERT INTO server_status (host, status_source, status_type, status_value)
    SELECT host, status_source, status_type, status_value
    FROM status;
END;
$$;


ALTER FUNCTION public.copy_status_to_server() OWNER TO postgres;

--
-- Name: copy_to_outbox_inference(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.copy_to_outbox_inference() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    INSERT INTO public.outbox_inference
    VALUES (NEW.*);
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.copy_to_outbox_inference() OWNER TO postgres;

--
-- Name: copy_to_outbox_trial(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.copy_to_outbox_trial() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
	INSERT INTO outbox_trial SELECT NEW.*;
	RETURN NEW;
END;
$$;


ALTER FUNCTION public.copy_to_outbox_trial() OWNER TO postgres;

--
-- Name: notify_copy_recent_stats(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.notify_copy_recent_stats() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    recent_stats_json text;
BEGIN
    -- Convert the entire recent_stats table into a JSON array
    SELECT json_agg(t)::text INTO recent_stats_json
    FROM (
        SELECT * FROM recent_stats
    ) t;

    -- Notify the "copy_recent_stats" channel with the JSON payload
    PERFORM pg_notify('copy_recent_stats', recent_stats_json);

    RETURN NULL; -- This is an AFTER trigger, so NULL is returned
END;
$$;


ALTER FUNCTION public.notify_copy_recent_stats() OWNER TO postgres;

--
-- Name: notify_copy_status(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.notify_copy_status() RETURNS trigger
    LANGUAGE plpgsql
    AS $$-- This function is triggered on an insert into status
-- It will attempt to send the entire row in a notification with the topic 'copy_status'
-- If the message is too big (>8000 KB) it will just send 'copy_status_oversized', 'exceeds 8kb'

DECLARE
    status_json      text;
    max_payload_size int := 8000;  -- Max size for pg_notify payload
BEGIN
    -- Only build JSON for the “main” cases
    IF NEW.status_type NOT IN ('em_pos','photo_cartoon','screenshot','system_script') THEN
        status_json := json_build_object(
            'host',          NEW.host,
            'status_source', NEW.status_source,
            'status_type',   NEW.status_type,
            'status_value',  NEW.status_value
        )::text;

        IF length(status_json) <= max_payload_size THEN
            PERFORM pg_notify('copy_status', status_json);
        ELSE
            PERFORM pg_notify('copy_status_oversized', 'exceeds 8kb');
        END IF;

    ELSIF NEW.status_type IN ('photo_cartoon','screenshot') AND NEW.status_value IS DISTINCT FROM OLD.status_value THEN
	    PERFORM pg_notify('new_image', NEW.status_type);
    END IF;

    -- in_obs stays as before
    IF NEW.status_type = 'in_obs' THEN
        PERFORM pg_notify('in_obs', NEW.status_value);
    END IF;

    RETURN NULL;  -- AFTER trigger
END;

$$;


ALTER FUNCTION public.notify_copy_status() OWNER TO postgres;

--
-- Name: notify_empty_outbox_inference(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.notify_empty_outbox_inference() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    PERFORM pg_notify('empty_outbox_inference', '');
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.notify_empty_outbox_inference() OWNER TO postgres;

--
-- Name: notify_outbox_trial_insert(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.notify_outbox_trial_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$BEGIN
    -- Notify the 'empty_outbox_trial' channel with the client's ID
    PERFORM pg_notify('empty_outbox_trial', '');
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.notify_outbox_trial_insert() OWNER TO postgres;

--
-- Name: process_trial_outbox(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.process_trial_outbox() RETURNS void
    LANGUAGE plpgsql
    AS $$DECLARE
    row RECORD;
BEGIN
    FOR row IN SELECT * FROM outbox_trial LOOP
        BEGIN
            -- Insert into the foreign table, leaving server_trial_id as DEFAULT
            INSERT INTO server_trial (
                base_trial_id, host, block_id, trial_id, project, state_system, protocol,
                variant, version, subject, status, rt, trialinfo, client_time
            )
            VALUES (
                row.base_trial_id, row.host, row.block_id, row.trial_id, row.project,
                row.state_system, row.protocol, row.variant, row.version, row.subject,
                row.status, row.rt, row.trialinfo, row.sys_time
            );

            -- Delete the processed row from the outbox
            DELETE FROM outbox_trial WHERE ctid = row.ctid;

        EXCEPTION
            WHEN SQLSTATE 'HV00L' THEN -- FDW-specific error (foreign server unavailable)
                RAISE NOTICE 'Foreign server unavailable. Skipping row: %', row;

            WHEN SQLSTATE '08000' THEN -- Connection exception
                RAISE NOTICE 'Connection error. Skipping row: %', row;

            WHEN OTHERS THEN
                -- Log unexpected errors
                RAISE NOTICE 'Unexpected error processing row: % - Error: %', row, SQLERRM;
        END;
    END LOOP;
END;
$$;


ALTER FUNCTION public.process_trial_outbox() OWNER TO postgres;

--
-- Name: update_all_recent_stats(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_all_recent_stats() RETURNS void
    LANGUAGE plpgsql
    AS $$DECLARE
    _row RECORD;
BEGIN
    -- Debugging: Log function start
    RAISE NOTICE 'Function update_all_recent_stats started';

    -- Step 1: Update existing rows in recent_stats to reflect current trial data
    UPDATE recent_stats
    SET
        aborts = COALESCE((SELECT COUNT(CASE WHEN status = -1 THEN 1 END) * 1.0 / NULLIF(COUNT(*), 0)
                           FROM trial
                           WHERE recent_stats.host = trial.host
                             AND recent_stats.subject = trial.subject
                             AND (recent_stats.project = trial.project OR recent_stats.project = '*')
                             AND (recent_stats.state_system = trial.state_system OR recent_stats.state_system = '*')
                             AND (recent_stats.protocol = trial.protocol OR recent_stats.protocol = '*')
                             AND (recent_stats.variant = trial.variant OR recent_stats.variant = '*')
                             AND trial.sys_time >=
                                 CASE
                                     WHEN recent_stats.status_type = 'day' THEN DATE_TRUNC('day', NOW())
                                     WHEN recent_stats.status_type = 'hour' THEN NOW() - INTERVAL '1 hour'
                                 END), 0),
        pc = COALESCE((SELECT AVG(CASE WHEN status >= 0 THEN status::FLOAT END)
                       FROM trial
                       WHERE recent_stats.host = trial.host
                         AND recent_stats.subject = trial.subject
                         AND (recent_stats.project = trial.project OR recent_stats.project = '*')
                         AND (recent_stats.state_system = trial.state_system OR recent_stats.state_system = '*')
                         AND (recent_stats.protocol = trial.protocol OR recent_stats.protocol = '*')
                         AND (recent_stats.variant = trial.variant OR recent_stats.variant = '*')
                         AND trial.sys_time >=
                             CASE
                                 WHEN recent_stats.status_type = 'day' THEN DATE_TRUNC('day', NOW())
                                 WHEN recent_stats.status_type = 'hour' THEN NOW() - INTERVAL '1 hour'
                             END), NULL),
        rt = COALESCE((SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY rt) FILTER (WHERE status >= 0)
                       FROM trial
                       WHERE recent_stats.host = trial.host
                         AND recent_stats.subject = trial.subject
                         AND (recent_stats.project = trial.project OR recent_stats.project = '*')
                         AND (recent_stats.state_system = trial.state_system OR recent_stats.state_system = '*')
                         AND (recent_stats.protocol = trial.protocol OR recent_stats.protocol = '*')
                         AND (recent_stats.variant = trial.variant OR recent_stats.variant = '*')
                         AND trial.sys_time >=
                             CASE
                                 WHEN recent_stats.status_type = 'day' THEN DATE_TRUNC('day', NOW())
                                 WHEN recent_stats.status_type = 'hour' THEN NOW() - INTERVAL '1 hour'
                             END), NULL),
        trials = COALESCE((SELECT COUNT(*)
                           FROM trial
                           WHERE recent_stats.host = trial.host
                             AND recent_stats.subject = trial.subject
                             AND (recent_stats.project = trial.project OR recent_stats.project = '*')
                             AND (recent_stats.state_system = trial.state_system OR recent_stats.state_system = '*')
                             AND (recent_stats.protocol = trial.protocol OR recent_stats.protocol = '*')
                             AND (recent_stats.variant = trial.variant OR recent_stats.variant = '*')
                             AND trial.sys_time >=
                                 CASE
                                     WHEN recent_stats.status_type = 'day' THEN DATE_TRUNC('day', NOW())
                                     WHEN recent_stats.status_type = 'hour' THEN NOW() - INTERVAL '1 hour'
                                 END), 0),
        last_updated = NOW()
    WHERE recent_stats.status_type != 'block' -- Ignore block rows
      AND EXISTS (
        SELECT 1
        FROM trial
        WHERE recent_stats.host = trial.host
          AND recent_stats.subject = trial.subject
          AND (recent_stats.project = trial.project OR recent_stats.project = '*')
          AND (recent_stats.state_system = trial.state_system OR recent_stats.state_system = '*')
          AND (recent_stats.protocol = trial.protocol OR recent_stats.protocol = '*')
          AND (recent_stats.variant = trial.variant OR recent_stats.variant = '*')
    );

    -- Debugging: Log update completed
    RAISE NOTICE 'Updated rows in recent_stats with current trial data';

    -- Step 2: Ensure rows for day/hour with zero trials exist for each host
    INSERT INTO recent_stats (
        status_type, host, subject, project, state_system, protocol, variant,
        aborts, pc, rt, trials, last_updated
    )
    SELECT DISTINCT
        status_type, host, subject, 
        CAST('*' AS text), CAST('*' AS text), CAST('*' AS text), CAST('*' AS text),
        0.0, 
        CAST(NULL AS double precision), 
        CAST(NULL AS double precision), 
        0, 
        NOW()
    FROM (
        SELECT 'day' AS status_type, host, subject FROM trial
        UNION
        SELECT 'hour' AS status_type, host, subject FROM trial
    ) AS derived
    WHERE NOT EXISTS (
        SELECT 1
        FROM recent_stats
        WHERE recent_stats.status_type = derived.status_type
          AND recent_stats.host = derived.host
          AND recent_stats.subject = derived.subject
    );

    -- Debugging: Log insertion of day/hour rows
    RAISE NOTICE 'Inserted missing day/hour rows into recent_stats';

    -- Step 3: Cleanup - Remove rows with zero trials
    DELETE FROM recent_stats
    WHERE trials = 0
      AND status_type != 'block' -- Do not delete block rows
      AND NOT (status_type IN ('day', 'hour') AND project = '*' AND state_system = '*' AND protocol = '*' AND variant = '*');

    -- Debugging: Log cleanup completed
    RAISE NOTICE 'Removed rows with zero trials from recent_stats';

    -- Debugging: Log function end
    RAISE NOTICE 'Function update_all_recent_stats completed';
END;
$$;


ALTER FUNCTION public.update_all_recent_stats() OWNER TO postgres;

--
-- Name: update_last_completed_trigger(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_last_completed_trigger() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Only proceed if status_type is 'obs_id' and the new status_value is greater than the old one
    IF NEW.status_type = 'obs_id' AND NEW.status_value::INTEGER > OLD.status_value::INTEGER THEN
        -- Upsert a row with status_source='ess', status_type='last_completed', status_value=current system time
        INSERT INTO status (host, status_source, status_type, status_value, sys_time)
        VALUES (NEW.host, 'ess', 'last_completed', CURRENT_TIMESTAMP::TEXT, DEFAULT)
        ON CONFLICT (host, status_source, status_type)
        DO UPDATE SET
            status_value = CURRENT_TIMESTAMP::TEXT,
            sys_time = DEFAULT;
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.update_last_completed_trigger() OWNER TO postgres;

--
-- Name: update_max_voltage(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_max_voltage() RETURNS trigger
    LANGUAGE plpgsql
    AS $_$
DECLARE
    current_max_value NUMERIC;
BEGIN
    -- RAISE NOTICE 'Trigger fired for host: %, status_type: %, status_value: %', 
        -- NEW.host, NEW.status_type, NEW.status_value;

    -- Check if the condition for updating the max voltage is met
    IF NEW.status_source = 'system' AND NEW.status_type = '24v-v' THEN
        -- RAISE NOTICE 'Condition met for updating max voltage.';

        -- Validate that NEW.status_value is numeric
        IF NEW.status_value ~ '^\d+(\.\d+)?$' THEN
            -- Retrieve the current max value
            SELECT status_value::NUMERIC
            INTO current_max_value
            FROM status
            WHERE status_source = 'system'
              AND status_type = '24v-v-max'
              AND host = NEW.host
            LIMIT 1;

            -- Log the current max value
            -- RAISE NOTICE 'Current max value for host %: %', NEW.host, current_max_value;

            -- Check if a max value exists for the given host
            IF current_max_value IS NULL THEN
                -- Initialize max value if no current max exists for this host
                -- RAISE NOTICE 'No max value exists for host %. Initializing it.', NEW.host;

                INSERT INTO status (status_source, status_type, status_value, host, sys_time)
                VALUES ('system', '24v-v-max', NEW.status_value, NEW.host, CURRENT_TIMESTAMP);
            ELSE
                -- Update max value if the new value is greater
                IF NEW.status_value::NUMERIC > current_max_value THEN
                    -- RAISE NOTICE 'Updating max value for host %. New value: %', NEW.host, NEW.status_value;

                    UPDATE status
                    SET status_value = NEW.status_value,
                        sys_time = CURRENT_TIMESTAMP
                    WHERE status_source = 'system'
                      AND status_type = '24v-v-max'
                      AND host = NEW.host;
                -- ELSE
                    -- RAISE NOTICE 'New value is not greater than current max. No update performed.';
                END IF;
            END IF;
        ELSE
            RAISE NOTICE 'Non-numeric value in status_value: %. Skipping max voltage update.', NEW.status_value;
        END IF;
    -- ELSE
        -- RAISE NOTICE 'Condition not met. Trigger exited.';
    END IF;

    RETURN NEW;
END;
$_$;


ALTER FUNCTION public.update_max_voltage() OWNER TO postgres;

--
-- Name: update_recent_stats(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_recent_stats() RETURNS trigger
    LANGUAGE plpgsql
    AS $$DECLARE
    _new_stats RECORD; -- Record to hold the updated stats
    _current_block_id BIGINT;    -- Variable to hold the most recent block_id
BEGIN
    -- Update specific 'day' stats
    FOR _new_stats IN
        SELECT
            'day' AS status_type,
            NEW.host,
            NEW.subject,
            NEW.project,
            NEW.state_system,
            NEW.protocol,
            NEW.variant,
            COUNT(CASE WHEN status = -1 THEN 1 END) * 1.0 / COUNT(*) AS aborts,
            AVG(CASE WHEN status >= 0 THEN status::FLOAT END) AS pc,
            percentile_cont(0.5) WITHIN GROUP (ORDER BY rt) FILTER (WHERE status >= 0) AS rt,
            COUNT(*) AS trials,
            NOW() AS last_updated
        FROM trial
        WHERE host = NEW.host
          AND subject = NEW.subject
          AND project = NEW.project
          AND state_system = NEW.state_system
          AND protocol = NEW.protocol
          AND variant = NEW.variant
          AND sys_time >= DATE_TRUNC('day', NOW()) -- Since midnight
        GROUP BY host, subject, project, state_system, protocol, variant
    LOOP
        INSERT INTO recent_stats (status_type, host, subject, project, state_system, protocol, variant, aborts, pc, rt, trials, last_updated)
        VALUES (
            _new_stats.status_type,
            _new_stats.host,
            _new_stats.subject,
            _new_stats.project,
            _new_stats.state_system,
            _new_stats.protocol,
            _new_stats.variant,
            _new_stats.aborts,
            _new_stats.pc,
            _new_stats.rt,
            _new_stats.trials,
            _new_stats.last_updated
        )
        ON CONFLICT (status_type, host, subject, project, state_system, protocol, variant)
        DO UPDATE SET
            aborts = EXCLUDED.aborts,
            pc = EXCLUDED.pc,
            rt = EXCLUDED.rt,
            trials = EXCLUDED.trials,
            last_updated = CASE
                WHEN recent_stats.aborts IS DISTINCT FROM EXCLUDED.aborts
                  OR recent_stats.pc IS DISTINCT FROM EXCLUDED.pc
                  OR recent_stats.rt IS DISTINCT FROM EXCLUDED.rt
                  OR recent_stats.trials IS DISTINCT FROM EXCLUDED.trials
                THEN EXCLUDED.last_updated
                ELSE recent_stats.last_updated
            END;
    END LOOP;

    -- Update wildcard 'day' stats
    FOR _new_stats IN
        SELECT
            'day' AS status_type,
            NEW.host,
            NEW.subject,
            '*' AS project,
            '*' AS state_system,
            '*' AS protocol,
            '*' AS variant,
            COUNT(CASE WHEN status = -1 THEN 1 END) * 1.0 / COUNT(*) AS aborts,
            AVG(CASE WHEN status >= 0 THEN status::FLOAT END) AS pc,
            percentile_cont(0.5) WITHIN GROUP (ORDER BY rt) FILTER (WHERE status >= 0) AS rt,
            COUNT(*) AS trials,
            NOW() AS last_updated
        FROM trial
        WHERE host = NEW.host
          AND subject = NEW.subject
          AND sys_time >= DATE_TRUNC('day', NOW()) -- Since midnight
        GROUP BY host, subject
    LOOP
        INSERT INTO recent_stats (status_type, host, subject, project, state_system, protocol, variant, aborts, pc, rt, trials, last_updated)
        VALUES (
            _new_stats.status_type,
            _new_stats.host,
            _new_stats.subject,
            _new_stats.project,
            _new_stats.state_system,
            _new_stats.protocol,
            _new_stats.variant,
            _new_stats.aborts,
            _new_stats.pc,
            _new_stats.rt,
            _new_stats.trials,
            _new_stats.last_updated
        )
        ON CONFLICT (status_type, host, subject, project, state_system, protocol, variant)
        DO UPDATE SET
            aborts = EXCLUDED.aborts,
            pc = EXCLUDED.pc,
            rt = EXCLUDED.rt,
            trials = EXCLUDED.trials,
            last_updated = CASE
                WHEN recent_stats.aborts IS DISTINCT FROM EXCLUDED.aborts
                  OR recent_stats.pc IS DISTINCT FROM EXCLUDED.pc
                  OR recent_stats.rt IS DISTINCT FROM EXCLUDED.rt
                  OR recent_stats.trials IS DISTINCT FROM EXCLUDED.trials
                THEN EXCLUDED.last_updated
                ELSE recent_stats.last_updated
            END;
    END LOOP;

    -- Repeat for 'hour' stats
    -- Update specific 'hour' stats
    FOR _new_stats IN
        SELECT
            'hour' AS status_type,
            NEW.host,
            NEW.subject,
            NEW.project,
            NEW.state_system,
            NEW.protocol,
            NEW.variant,
            COUNT(CASE WHEN status = -1 THEN 1 END) * 1.0 / COUNT(*) AS aborts,
            AVG(CASE WHEN status >= 0 THEN status::FLOAT END) AS pc,
            percentile_cont(0.5) WITHIN GROUP (ORDER BY rt) FILTER (WHERE status >= 0) AS rt,
            COUNT(*) AS trials,
            NOW() AS last_updated
        FROM trial
        WHERE host = NEW.host
          AND subject = NEW.subject
          AND project = NEW.project
          AND state_system = NEW.state_system
          AND protocol = NEW.protocol
          AND variant = NEW.variant
          AND sys_time >= NOW() - INTERVAL '1 hour' -- Within the last hour
        GROUP BY host, subject, project, state_system, protocol, variant
    LOOP
        INSERT INTO recent_stats (status_type, host, subject, project, state_system, protocol, variant, aborts, pc, rt, trials, last_updated)
        VALUES (
            _new_stats.status_type,
            _new_stats.host,
            _new_stats.subject,
            _new_stats.project,
            _new_stats.state_system,
            _new_stats.protocol,
            _new_stats.variant,
            _new_stats.aborts,
            _new_stats.pc,
            _new_stats.rt,
            _new_stats.trials,
            _new_stats.last_updated
        )
        ON CONFLICT (status_type, host, subject, project, state_system, protocol, variant)
        DO UPDATE SET
            aborts = EXCLUDED.aborts,
            pc = EXCLUDED.pc,
            rt = EXCLUDED.rt,
            trials = EXCLUDED.trials,
            last_updated = CASE
                WHEN recent_stats.aborts IS DISTINCT FROM EXCLUDED.aborts
                  OR recent_stats.pc IS DISTINCT FROM EXCLUDED.pc
                  OR recent_stats.rt IS DISTINCT FROM EXCLUDED.rt
                  OR recent_stats.trials IS DISTINCT FROM EXCLUDED.trials
                THEN EXCLUDED.last_updated
                ELSE recent_stats.last_updated
            END;
    END LOOP;

    -- Update wildcard 'hour' stats
    FOR _new_stats IN
        SELECT
            'hour' AS status_type,
            NEW.host,
            NEW.subject,
            '*' AS project,
            '*' AS state_system,
            '*' AS protocol,
            '*' AS variant,
            COUNT(CASE WHEN status = -1 THEN 1 END) * 1.0 / COUNT(*) AS aborts,
            AVG(CASE WHEN status >= 0 THEN status::FLOAT END) AS pc,
            percentile_cont(0.5) WITHIN GROUP (ORDER BY rt) FILTER (WHERE status >= 0) AS rt,
            COUNT(*) AS trials,
            NOW() AS last_updated
        FROM trial
        WHERE host = NEW.host
          AND subject = NEW.subject
          AND sys_time >= NOW() - INTERVAL '1 hour' -- Within the last hour
        GROUP BY host, subject
    LOOP
        INSERT INTO recent_stats (status_type, host, subject, project, state_system, protocol, variant, aborts, pc, rt, trials, last_updated)
        VALUES (
            _new_stats.status_type,
            _new_stats.host,
            _new_stats.subject,
            _new_stats.project,
            _new_stats.state_system,
            _new_stats.protocol,
            _new_stats.variant,
            _new_stats.aborts,
            _new_stats.pc,
            _new_stats.rt,
            _new_stats.trials,
            _new_stats.last_updated
        )
        ON CONFLICT (status_type, host, subject, project, state_system, protocol, variant)
        DO UPDATE SET
            aborts = EXCLUDED.aborts,
            pc = EXCLUDED.pc,
            rt = EXCLUDED.rt,
            trials = EXCLUDED.trials,
            last_updated = CASE
                WHEN recent_stats.aborts IS DISTINCT FROM EXCLUDED.aborts
                  OR recent_stats.pc IS DISTINCT FROM EXCLUDED.pc
                  OR recent_stats.rt IS DISTINCT FROM EXCLUDED.rt
                  OR recent_stats.trials IS DISTINCT FROM EXCLUDED.trials
                THEN EXCLUDED.last_updated
                ELSE recent_stats.last_updated
            END;
    END LOOP;

	-- Update 'block' stats
	-- Step 1: Delete all rows where status_type = 'block'
DELETE FROM recent_stats
WHERE status_type = 'block';

-- Step 2: Fetch the most recent block_id for the host and subject
SELECT block_id
INTO STRICT _current_block_id
FROM trial
ORDER BY sys_time DESC
LIMIT 1;

-- Step 3: Calculate stats for the current block_id
FOR _new_stats IN
    SELECT
        'block' AS status_type,
        NEW.host AS host,
        NEW.subject AS subject,
        NEW.project AS project,            -- Take project from NEW
        NEW.state_system AS state_system,  -- Take state_system from NEW
        NEW.protocol AS protocol,          -- Take protocol from NEW
        NEW.variant AS variant,            -- Take variant from NEW
        COUNT(CASE WHEN status = -1 THEN 1 END) * 1.0 / COUNT(*) AS aborts,
        AVG(CASE WHEN status >= 0 THEN status::FLOAT END) AS pc,
        percentile_cont(0.5) WITHIN GROUP (ORDER BY rt) FILTER (WHERE status >= 0) AS rt,
        COUNT(*) AS trials,
        NOW() AS last_updated
    FROM trial
    WHERE block_id = _current_block_id
      AND host = NEW.host  -- Match only relevant rows
      AND subject = NEW.subject
      AND project = NEW.project
      AND state_system = NEW.state_system
      AND protocol = NEW.protocol
      AND variant = NEW.variant
    GROUP BY NEW.host, NEW.subject, NEW.project, NEW.state_system, NEW.protocol, NEW.variant
LOOP
    INSERT INTO recent_stats (status_type, host, subject, project, state_system, protocol, variant, aborts, pc, rt, trials, last_updated)
    VALUES (
        _new_stats.status_type,
        _new_stats.host,
        _new_stats.subject,
        _new_stats.project,
        _new_stats.state_system,
        _new_stats.protocol,
        _new_stats.variant,
        _new_stats.aborts,
        _new_stats.pc,
        _new_stats.rt,
        _new_stats.trials,
        _new_stats.last_updated
    );
END LOOP;
    

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.update_recent_stats() OWNER TO postgres;

--
-- Name: remote_server; Type: SERVER; Schema: -; Owner: postgres
--

CREATE SERVER remote_server FOREIGN DATA WRAPPER postgres_fdw OPTIONS (
    dbname 'base',
    host '192.168.4.228'
);


ALTER SERVER remote_server OWNER TO postgres;

--
-- Name: USER MAPPING postgres SERVER remote_server; Type: USER MAPPING; Schema: -; Owner: postgres
--

CREATE USER MAPPING FOR postgres SERVER remote_server OPTIONS (
    password 'postgres',
    "user" 'postgres'
);


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: inference; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.inference (
    infer_id integer NOT NULL,
    meta_file text,
    model_file text,
    host inet,
    infer_label text,
    manual_label text,
    input_data bytea,
    mime_type text,
    client_time timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    confidence numeric(3,2),
    trial_time integer,
    CONSTRAINT inference_confidence_check CHECK (((confidence >= (0)::numeric) AND (confidence <= (1)::numeric)))
);


ALTER TABLE public.inference OWNER TO postgres;

--
-- Name: COLUMN inference.infer_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.inference.infer_id IS 'unique row identifier';


--
-- Name: COLUMN inference.meta_file; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.inference.meta_file IS 'filename that describes model and image input expectations';


--
-- Name: COLUMN inference.model_file; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.inference.model_file IS 'filename of trained model';


--
-- Name: COLUMN inference.host; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.inference.host IS 'IP address of machine taking photo';


--
-- Name: COLUMN inference.infer_label; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.inference.infer_label IS 'label that comes out of the inference';


--
-- Name: COLUMN inference.manual_label; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.inference.manual_label IS 'optional label from humans';


--
-- Name: COLUMN inference.input_data; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.inference.input_data IS 'bytes of the source data';


--
-- Name: COLUMN inference.mime_type; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.inference.mime_type IS 'file format of input_data';


--
-- Name: COLUMN inference.client_time; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.inference.client_time IS 'auto-generated timestamp';


--
-- Name: COLUMN inference.confidence; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.inference.confidence IS 'models confidence in the inference';


--
-- Name: COLUMN inference.trial_time; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.inference.trial_time IS 'integer time in milliseconds since last obs_on';


--
-- Name: inference_infer_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.inference_infer_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.inference_infer_id_seq OWNER TO postgres;

--
-- Name: inference_infer_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.inference_infer_id_seq OWNED BY public.inference.infer_id;


--
-- Name: outbox_inference; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.outbox_inference (
    infer_id integer DEFAULT nextval('public.inference_infer_id_seq'::regclass) NOT NULL,
    meta_file text,
    model_file text,
    host inet,
    infer_label text,
    manual_label text,
    input_data bytea,
    mime_type text,
    client_time timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    confidence numeric(3,2),
    trial_time integer
);


ALTER TABLE public.outbox_inference OWNER TO postgres;

--
-- Name: outbox_trial; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.outbox_trial (
    base_trial_id integer NOT NULL,
    host character varying(256),
    block_id integer,
    trial_id integer,
    project text,
    state_system text,
    protocol text,
    variant text,
    version text,
    subject text,
    status integer,
    rt integer,
    trialinfo jsonb,
    sys_time timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.outbox_trial OWNER TO postgres;

--
-- Name: recent_stats; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.recent_stats (
    status_type character varying(10) NOT NULL,
    host character varying(255) NOT NULL,
    subject character varying(255) NOT NULL,
    project character varying(255) NOT NULL,
    state_system character varying(255) NOT NULL,
    protocol character varying(255) NOT NULL,
    variant character varying(255) NOT NULL,
    aborts double precision,
    pc double precision,
    rt double precision,
    trials integer,
    last_updated timestamp without time zone
);


ALTER TABLE public.recent_stats OWNER TO postgres;

--
-- Name: server_recent_stats; Type: FOREIGN TABLE; Schema: public; Owner: postgres
--

CREATE FOREIGN TABLE public.server_recent_stats (
    status_type character varying(10) NOT NULL,
    host character varying(255) NOT NULL,
    subject character varying(255) NOT NULL,
    project character varying(255) NOT NULL,
    state_system character varying(255) NOT NULL,
    protocol character varying(255) NOT NULL,
    variant character varying(255) NOT NULL,
    aborts double precision,
    pc double precision,
    rt double precision,
    trials integer,
    last_updated timestamp without time zone
)
SERVER remote_server
OPTIONS (
    table_name 'server_recent_stats'
);


ALTER FOREIGN TABLE public.server_recent_stats OWNER TO postgres;

--
-- Name: server_status; Type: FOREIGN TABLE; Schema: public; Owner: postgres
--

CREATE FOREIGN TABLE public.server_status (
    host text,
    status_source text,
    status_type text,
    status_value text,
    server_time timestamp without time zone
)
SERVER remote_server
OPTIONS (
    table_name 'server_status'
);


ALTER FOREIGN TABLE public.server_status OWNER TO postgres;

--
-- Name: server_trial; Type: FOREIGN TABLE; Schema: public; Owner: postgres
--

CREATE FOREIGN TABLE public.server_trial (
    server_trial_id integer NOT NULL,
    base_trial_id integer,
    host character varying(256),
    block_id integer,
    trial_id integer,
    project text,
    state_system text,
    protocol text,
    variant text,
    version text,
    subject text,
    status integer,
    rt integer,
    trialinfo jsonb,
    client_time timestamp with time zone,
    server_time timestamp with time zone
)
SERVER remote_server
OPTIONS (
    schema_name 'public',
    table_name 'server_trial'
);
ALTER FOREIGN TABLE ONLY public.server_trial ALTER COLUMN server_trial_id OPTIONS (
    column_name 'server_trial_id'
);
ALTER FOREIGN TABLE ONLY public.server_trial ALTER COLUMN base_trial_id OPTIONS (
    column_name 'base_trial_id'
);
ALTER FOREIGN TABLE ONLY public.server_trial ALTER COLUMN host OPTIONS (
    column_name 'host'
);
ALTER FOREIGN TABLE ONLY public.server_trial ALTER COLUMN block_id OPTIONS (
    column_name 'block_id'
);
ALTER FOREIGN TABLE ONLY public.server_trial ALTER COLUMN trial_id OPTIONS (
    column_name 'trial_id'
);
ALTER FOREIGN TABLE ONLY public.server_trial ALTER COLUMN project OPTIONS (
    column_name 'project'
);
ALTER FOREIGN TABLE ONLY public.server_trial ALTER COLUMN state_system OPTIONS (
    column_name 'state_system'
);
ALTER FOREIGN TABLE ONLY public.server_trial ALTER COLUMN protocol OPTIONS (
    column_name 'protocol'
);
ALTER FOREIGN TABLE ONLY public.server_trial ALTER COLUMN variant OPTIONS (
    column_name 'variant'
);
ALTER FOREIGN TABLE ONLY public.server_trial ALTER COLUMN version OPTIONS (
    column_name 'version'
);
ALTER FOREIGN TABLE ONLY public.server_trial ALTER COLUMN subject OPTIONS (
    column_name 'subject'
);
ALTER FOREIGN TABLE ONLY public.server_trial ALTER COLUMN status OPTIONS (
    column_name 'status'
);
ALTER FOREIGN TABLE ONLY public.server_trial ALTER COLUMN rt OPTIONS (
    column_name 'rt'
);
ALTER FOREIGN TABLE ONLY public.server_trial ALTER COLUMN trialinfo OPTIONS (
    column_name 'trialinfo'
);
ALTER FOREIGN TABLE ONLY public.server_trial ALTER COLUMN client_time OPTIONS (
    column_name 'client_time'
);
ALTER FOREIGN TABLE ONLY public.server_trial ALTER COLUMN server_time OPTIONS (
    column_name 'server_time'
);


ALTER FOREIGN TABLE public.server_trial OWNER TO postgres;

--
-- Name: status; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.status (
    host character varying(256) NOT NULL,
    status_source text NOT NULL,
    status_type text NOT NULL,
    status_value text,
    sys_time timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.status OWNER TO postgres;

--
-- Name: trial; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.trial (
    base_trial_id integer NOT NULL,
    host character varying(256),
    block_id integer,
    trial_id integer,
    project text,
    state_system text,
    protocol text,
    variant text,
    version text,
    subject text,
    status integer,
    rt integer,
    trialinfo jsonb,
    sys_time timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.trial OWNER TO postgres;

--
-- Name: trial_base_trial_id_seq_unused; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.trial ALTER COLUMN base_trial_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.trial_base_trial_id_seq_unused
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: inference infer_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.inference ALTER COLUMN infer_id SET DEFAULT nextval('public.inference_infer_id_seq'::regclass);


--
-- Name: inference inference_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.inference
    ADD CONSTRAINT inference_pkey PRIMARY KEY (infer_id);


--
-- Name: recent_stats recent_stats_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.recent_stats
    ADD CONSTRAINT recent_stats_pkey PRIMARY KEY (status_type, host, subject, project, state_system, protocol, variant);


--
-- Name: status status_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.status
    ADD CONSTRAINT status_pkey PRIMARY KEY (host, status_source, status_type);


--
-- Name: status status_status_type_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.status
    ADD CONSTRAINT status_status_type_key UNIQUE (status_type);


--
-- Name: trial trial_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.trial
    ADD CONSTRAINT trial_pkey PRIMARY KEY (base_trial_id);


--
-- Name: recent_stats notify_copy_recent_stats_trigger; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER notify_copy_recent_stats_trigger AFTER INSERT OR DELETE OR UPDATE ON public.recent_stats FOR EACH STATEMENT EXECUTE FUNCTION public.notify_copy_recent_stats();


--
-- Name: outbox_trial notify_on_trial_insert; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER notify_on_trial_insert AFTER INSERT ON public.outbox_trial FOR EACH ROW EXECUTE FUNCTION public.notify_outbox_trial_insert();


--
-- Name: inference trg_copy_to_outbox_inference; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_copy_to_outbox_inference AFTER INSERT ON public.inference FOR EACH ROW EXECUTE FUNCTION public.copy_to_outbox_inference();


--
-- Name: outbox_inference trg_notify_empty_outbox_inference; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_notify_empty_outbox_inference AFTER INSERT ON public.outbox_inference FOR EACH ROW EXECUTE FUNCTION public.notify_empty_outbox_inference();


--
-- Name: status trg_update_24v_v_max; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_24v_v_max AFTER INSERT OR UPDATE ON public.status FOR EACH ROW EXECUTE FUNCTION public.update_max_voltage();


--
-- Name: trial trigger_copy_to_outbox_trial; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trigger_copy_to_outbox_trial AFTER INSERT ON public.trial FOR EACH ROW EXECUTE FUNCTION public.copy_to_outbox_trial();


--
-- Name: status trigger_notify_copy_status; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trigger_notify_copy_status AFTER INSERT OR UPDATE ON public.status FOR EACH ROW EXECUTE FUNCTION public.notify_copy_status();


--
-- Name: trial trigger_notify_outbox_trial_insert; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trigger_notify_outbox_trial_insert AFTER INSERT ON public.trial FOR EACH ROW EXECUTE FUNCTION public.notify_outbox_trial_insert();


--
-- Name: status update_obs_id_last_completed; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_obs_id_last_completed AFTER UPDATE ON public.status FOR EACH ROW WHEN ((new.status_type = 'obs_id'::text)) EXECUTE FUNCTION public.update_last_completed_trigger();


--
-- Name: trial update_recent_stats_trigger; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_recent_stats_trigger AFTER INSERT ON public.trial FOR EACH ROW EXECUTE FUNCTION public.update_recent_stats();


--
-- PostgreSQL database dump complete
--

