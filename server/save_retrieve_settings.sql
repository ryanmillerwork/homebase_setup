CREATE OR REPLACE FUNCTION save_task_settings(
  p_host text
) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  ltxt   text;     -- JSON text from variant_info_json
  ptxt   text;     -- plain text from param_settings
  ljson  jsonb;
  names  text[];
  vals   text[];
  i      int;
  variant_args_str text := '';
  param_settings_str text := '';
  argval text;            -- current argument value (trimmed)
  value_token text;       -- token to append (handles empty/whitespace cases)

  -- Variables for the additional columns
  v_subject text;
  v_project text;
  v_state_system text;
  v_protocol text;
  v_variant text;
BEGIN
    -- Get additional required columns from server_status
  SELECT
    MAX(CASE WHEN status_type = 'subject' THEN status_value END),
    MAX(CASE WHEN status_type = 'project' THEN status_value END),
    MAX(CASE WHEN status_type = 'system' THEN status_value END),
    MAX(CASE WHEN status_type = 'protocol' THEN status_value END),
    MAX(CASE WHEN status_type = 'variant' THEN status_value END)
  INTO
    v_subject, v_project, v_state_system, v_protocol, v_variant
  FROM server_status
  WHERE host = p_host
    AND status_source = 'ess'
    AND status_type IN ('subject', 'project', 'system', 'protocol', 'variant');

  -- Check that all required fields are present
  IF v_subject IS NULL THEN
    RAISE EXCEPTION 'No subject found for host=%', p_host;
  END IF;
  IF v_project IS NULL THEN
    RAISE EXCEPTION 'No project found for host=%', p_host;
  END IF;
  IF v_state_system IS NULL THEN
    RAISE EXCEPTION 'No state_system found for host=%', p_host;
  END IF;
  IF v_protocol IS NULL THEN
    RAISE EXCEPTION 'No protocol found for host=%', p_host;
  END IF;
  IF v_variant IS NULL THEN
    RAISE EXCEPTION 'No variant found for host=%', p_host;
  END IF;

  -- Get loader JSON (variant_info_json)
  SELECT status_value
  INTO   ltxt
  FROM   server_status
  WHERE  host = p_host
     AND status_source = 'ess'
     AND status_type = 'variant_info_json';

  IF ltxt IS NULL THEN
    RAISE EXCEPTION 'No variant_info_json for host=%', p_host;
  END IF;

  ljson := ltxt::jsonb;

  names := ARRAY(SELECT jsonb_array_elements_text(ljson->'loader_arg_names'));
  vals  := ARRAY(SELECT jsonb_array_elements_text(ljson->'loader_args'));

  IF array_length(names,1) IS DISTINCT FROM array_length(vals,1) THEN
    RAISE EXCEPTION 'Name/value length mismatch for host=% (% vs %)',
      p_host, array_length(names,1), array_length(vals,1);
  END IF;

  -- Build variant_args string (without outer braces)
  -- Rule: if value is empty or NULL, emit '{}'
  --       if value contains whitespace, wrap as '{ <value> }'
  --       otherwise emit as-is
  FOR i IN 1..COALESCE(array_length(names,1),0) LOOP
    argval := btrim(COALESCE(vals[i], ''));
    IF argval = '' THEN
      value_token := '{}';
    ELSIF argval ~ '\s' THEN
      value_token := format('{ %s }', argval);
    ELSE
      value_token := argval;
    END IF;
    variant_args_str := variant_args_str || format('%s %s ', btrim(names[i]), value_token);
  END LOOP;
  variant_args_str := rtrim(variant_args_str);

  -- Get param_settings (raw text)
  SELECT status_value
  INTO   ptxt
  FROM   server_status
  WHERE  host = p_host
     AND status_source = 'ess'
     AND status_type = 'param_settings';

  IF ptxt IS NULL THEN
    RAISE EXCEPTION 'No param_settings for host=%', p_host;
  END IF;

  -- Simplify param_settings: keep only first value from each { ... }
  -- Example: "interblock_time {1000 1 int}" -> "interblock_time 1000"
  param_settings_str :=
    regexp_replace(
      ptxt,
      '\{([^ \}]+)[^}]*\}',  -- capture first token inside braces
      '\1',
      'g'
    );
  param_settings_str := btrim(param_settings_str);

    -- Upsert into saved_settings table
  INSERT INTO saved_settings (
    subject, project, state_system, protocol, variant, variant_args, param_settings
  ) VALUES (
    v_subject, v_project, v_state_system, v_protocol, v_variant,
    '{' || variant_args_str || '}', param_settings_str
  )
  ON CONFLICT (subject, project, state_system, protocol, variant)
  DO UPDATE SET
    variant_args = EXCLUDED.variant_args,
    param_settings = EXCLUDED.param_settings;

END;
$$;

-- Example usage:
-- SELECT save_task_settings('192.168.4.201');

CREATE OR REPLACE FUNCTION retrieve_task_settings(
  p_host text
) RETURNS TABLE(
  result_status text,
  variant_args text,
  param_settings text
)
LANGUAGE plpgsql
AS $$
DECLARE
  -- Variables for the lookup columns
  v_subject text;
  v_project text;
  v_state_system text;
  v_protocol text;
  v_variant text;

  -- Variables for the results
  v_variant_args text;
  v_param_settings text;
BEGIN
  -- Get the lookup columns from server_status for the given host
  SELECT
    MAX(CASE WHEN status_type = 'subject' THEN status_value END),
    MAX(CASE WHEN status_type = 'project' THEN status_value END),
    MAX(CASE WHEN status_type = 'system' THEN status_value END),
    MAX(CASE WHEN status_type = 'protocol' THEN status_value END),
    MAX(CASE WHEN status_type = 'variant' THEN status_value END)
  INTO
    v_subject, v_project, v_state_system, v_protocol, v_variant
  FROM server_status
  WHERE host = p_host
    AND status_source = 'ess'
    AND status_type IN ('subject', 'project', 'system', 'protocol', 'variant');

  -- Check that all required fields are present
  IF v_subject IS NULL OR v_project IS NULL OR v_state_system IS NULL OR
     v_protocol IS NULL OR v_variant IS NULL THEN
    RETURN QUERY SELECT 'row not found'::text, ''::text, ''::text;
    RETURN;
  END IF;

  -- Look up the saved settings
  SELECT ss.variant_args, ss.param_settings
  INTO v_variant_args, v_param_settings
  FROM saved_settings ss
  WHERE ss.subject = v_subject
    AND ss.project = v_project
    AND ss.state_system = v_state_system
    AND ss.protocol = v_protocol
    AND ss.variant = v_variant;

  -- Return results
  IF v_variant_args IS NULL THEN
    RETURN QUERY SELECT 'row not found'::text, ''::text, ''::text;
  ELSE
    RETURN QUERY SELECT 'found'::text, v_variant_args, v_param_settings;
  END IF;

END;
$$;

-- Example usage:
-- SELECT * FROM retrieve_task_settings('192.168.4.201');
