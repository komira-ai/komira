-- The oracle discipline: oracle_offences(q) lists what is wrong with the
-- text of an oracle case, read on DuckDB's own parse of it
-- (json_serialize_sql), one row per offence. run.sql fails the case's
-- oracle when it lists any; discipline_check.sql holds it to planted
-- violations. The rules (README.md, The oracle discipline):
--   - the case is one SELECT;
--   - its outermost query has an ORDER BY (the expected file's row order is
--     the query's, never the order DuckDB happened to produce);
--   - every ORDER BY key, anywhere (the query's, a subquery's, a window's
--     OVER clause, an aggregate's own), states ASC or DESC and NULLS FIRST
--     or NULLS LAST, so no answer reads default_order or
--     default_null_order;
--   - an aggregate whose answer depends on the order rows reach it has an
--     ORDER BY of its own, as a plain aggregate or in its OVER clause, and
--     so does a window function that reads row positions;
--   - a window whose frame has a ROWS bound (start or end CURRENT_ROW_ROWS,
--     EXPR_PRECEDING_ROWS or EXPR_FOLLOWING_ROWS) has an ORDER BY in its
--     OVER clause, whatever the function: a ROWS frame counts rows in the
--     order they reach the window, and the function's own ORDER BY orders
--     only the rows inside the frame (a RANGE or GROUPS frame with no ORDER
--     BY is the whole partition: every row is a peer);
--   - a LIMIT or an OFFSET (LIMIT_MODIFIER, LIMIT_PERCENT_MODIFIER), and a
--     DISTINCT ON (a DISTINCT_MODIFIER with distinct_on_targets), has a
--     non-empty ORDER BY among the modifiers of its own query node; an
--     ORDER BY of a query around it or below it does not count;
--   - histogram with one argument takes a CAST to a type other than FLOAT,
--     DOUBLE or a name the parse leaves UNBOUND (DuckDB keys a float
--     histogram in a std::map under `<`, where NaN is equivalent to every
--     key and -0.0 to 0.0, so the answer follows the rows' order);
--     histogram with bins and histogram_exact take bins that name no column
--     at any depth (DuckDB fixes a group's bins from its first row);
--   - json_group_array, json_group_object and json_group_structure, macros
--     over string_agg with no ORDER BY, are refused, and so are
--     list_reverse_sort and array_reverse_sort (they always read
--     default_order);
--   - no call reads the clock, a random draw or the session: a function in
--     unstable_functions() (every scalar or aggregate DuckDB v1.5.6 marks
--     VOLATILE or CONSISTENT_WITHIN_QUERY but error, ICU's clock readers,
--     the session's settings and variables, the functions whose argument is
--     SQL text or whose answer is the running DuckDB, and the built-in
--     macros over any of these), a function named duckdb_* or pragma_*, a
--     table function that runs SQL text (sql_text_functions()), or age()
--     with one argument (it subtracts from today's midnight);
--   - no SQL value keyword: DuckDB parses `current_date` (quoted or not)
--     as a COLUMN_REF and its binder calls the clock or session function
--     the name maps to when no column has that name; a COLUMN_REF whose
--     last name is one of value_keywords() is refused however qualified,
--     which refuses more than DuckDB would (a column of such a name in an
--     oracle table must be renamed);
--   - no USING SAMPLE or TABLESAMPLE (a random draw kept in the `sample`
--     key of the SELECT or the table reference, not as a call).
-- threads = 1 and TimeZone = 'UTC' are the sql_oracle rule's own settings,
-- fixed before any of this SQL runs and locked.
CREATE MACRO order_sensitive_aggregates() AS [
    'first', 'arbitrary', 'last', 'any_value', 'list', 'array_agg', 'string_agg', 'group_concat', 'listagg',
    'arg_min', 'arg_max', 'arg_min_null', 'arg_max_null', 'argmin', 'argmax', 'min_by', 'max_by',
    'mode', 'approx_top_k', 'approx_quantile', 'reservoir_quantile'];
CREATE MACRO positional_windows() AS [
    'row_number', 'ntile', 'lead', 'lag', 'first_value', 'last_value', 'nth_value', 'fill'];
CREATE MACRO refused_functions() AS ['json_group_array', 'json_group_object', 'json_group_structure'];
CREATE MACRO reverse_sorts() AS ['list_reverse_sort', 'array_reverse_sort'];
CREATE MACRO histograms() AS ['histogram', 'histogram_exact'];
CREATE MACRO unstable_functions() AS [
    -- CONSISTENT_WITHIN_QUERY: a clock or the session.
    'current_database', 'current_date', 'current_schema', 'current_schemas', 'get_current_time',
    'get_current_timestamp', 'in_search_path', 'now', 'today', 'transaction_timestamp', 'txid_current',
    -- VOLATILE.
    'current_connection_id', 'current_query', 'current_query_id', 'current_transaction_id', 'currval',
    'gen_random_uuid', 'nextval', 'random', 'setseed', 'sleep_ms', 'stats', 'uuid', 'uuidv4', 'uuidv7', 'write_log',
    -- ICU's clock readers DuckDB leaves CONSISTENT; settings and variables.
    'current_localtime', 'current_localtimestamp', 'current_setting', 'getvariable',
    -- CONSISTENT, but answering with more than their arguments: SQL text
    -- planned or parsed on the session, a name looked up in the catalog or
    -- the loaded extensions, the running DuckDB itself.
    'json_serialize_plan', 'json_serialize_sql', 'json_deserialize_sql', 'make_type',
    'parse_duckdb_log_message', 'st_setcrs', 'version', 'vector_type',
    -- Called by these names they are the clock too (`current_time()`).
    'current_time', 'current_timestamp', 'localtime', 'localtimestamp',
    -- Built-in scalar macros over the above, the catalog or the session.
    'ago', 'current_catalog', 'format_type', 'get_block_size', 'pg_conf_load_time', 'pg_get_constraintdef',
    'pg_get_viewdef', 'pg_postmaster_start_time', 'pg_sleep'];
CREATE MACRO sql_text_functions() AS ['query', 'query_table', 'json_execute_serialized_sql'];
-- GetSQLValueFunctionName's map in DuckDB v1.5.6: a column name the binder
-- cannot resolve, which it calls as a function instead.
CREATE MACRO value_keywords() AS [
    'current_catalog', 'current_date', 'current_role', 'current_schema', 'current_time', 'current_timestamp',
    'current_user', 'localtime', 'localtimestamp', 'session_user', 'user'];

-- (json_extract and json_extract_string, not -> and ->>: inside a function
-- call this release can read `x->'key'` as a lambda.)
CREATE MACRO oracle_offences(q) AS TABLE
WITH parsed AS (SELECT CAST(json_serialize_sql(CAST(q AS VARCHAR)) AS JSON) AS j),
ok AS (SELECT j FROM parsed WHERE NOT CAST(json_extract_string(j, '$.error') AS BOOLEAN)),
nodes AS (SELECT t.value AS v FROM ok, json_tree(ok.j) AS t WHERE t.type = 'OBJECT'),
located AS (
    SELECT v,
        json_extract_string(v, '$.type') AS kind,
        json_extract_string(v, '$.class') AS class,
        lower(json_extract_string(v, '$.function_name')) AS fn,
        ' at byte ' || coalesce(json_extract_string(v, '$.query_location'), json_extract_string(v, '$.expression.query_location'), '?') AS loc
    FROM nodes)
SELECT 'is not one SELECT: ' || json_extract_string(j, '$.error_message') AS offence
FROM parsed WHERE CAST(json_extract_string(j, '$.error') AS BOOLEAN)
UNION ALL
SELECT 'holds ' || json_array_length(j, '$.statements') || ' statements, not one SELECT' FROM ok
WHERE json_array_length(j, '$.statements') <> 1
UNION ALL
SELECT 'its outermost query has no ORDER BY' FROM ok
WHERE NOT EXISTS (
    SELECT 1 FROM json_each(json_extract(ok.j, '$.statements[0].node.modifiers')) AS m
    WHERE json_extract_string(m.value, '$.type') = 'ORDER_MODIFIER' AND json_array_length(m.value, '$.orders') > 0)
UNION ALL
SELECT 'the ORDER BY key' || loc || ' states no ASC or DESC' FROM located
WHERE json_exists(v, '$.null_order') AND kind NOT IN ('ASCENDING', 'DESCENDING')
UNION ALL
SELECT 'the ORDER BY key' || loc || ' states no NULLS FIRST or NULLS LAST' FROM located
WHERE json_exists(v, '$.null_order') AND json_extract_string(v, '$.null_order') NOT IN ('NULLS FIRST', 'NULLS LAST')
UNION ALL
SELECT 'the aggregate ' || fn || loc || ' has no ORDER BY of its own, so its answer depends on the order rows reach it' FROM located
WHERE class = 'FUNCTION' AND list_contains(order_sensitive_aggregates(), fn)
  AND coalesce(json_array_length(v, '$.order_bys.orders'), 0) = 0
UNION ALL
SELECT 'the window function ' || fn || loc || ' has no ORDER BY in its OVER clause or of its own' FROM located
WHERE class = 'WINDOW' AND (list_contains(order_sensitive_aggregates(), fn) OR list_contains(positional_windows(), fn))
  AND coalesce(json_array_length(v, '$.orders'), 0) = 0 AND coalesce(json_array_length(v, '$.arg_orders'), 0) = 0
UNION ALL
SELECT 'the window function ' || fn || loc || ' has a ROWS frame and no ORDER BY in its OVER clause, so the frame counts rows in the order they reach it' FROM located
WHERE class = 'WINDOW' AND coalesce(json_array_length(v, '$.orders'), 0) = 0
  AND (json_extract_string(v, '$.start') IN ('CURRENT_ROW_ROWS', 'EXPR_PRECEDING_ROWS', 'EXPR_FOLLOWING_ROWS')
    OR json_extract_string(v, '$.end') IN ('CURRENT_ROW_ROWS', 'EXPR_PRECEDING_ROWS', 'EXPR_FOLLOWING_ROWS'))
UNION ALL
SELECT 'a LIMIT or OFFSET with no ORDER BY in the same query keeps the rows DuckDB reaches first' FROM located
WHERE json_type(v, '$.modifiers') = 'ARRAY'
  AND EXISTS (SELECT 1 FROM json_each(json_extract(v, '$.modifiers')) AS m
    WHERE json_extract_string(m.value, '$.type') IN ('LIMIT_MODIFIER', 'LIMIT_PERCENT_MODIFIER'))
  AND NOT EXISTS (SELECT 1 FROM json_each(json_extract(v, '$.modifiers')) AS m
    WHERE json_extract_string(m.value, '$.type') = 'ORDER_MODIFIER' AND json_array_length(m.value, '$.orders') > 0)
UNION ALL
SELECT 'DISTINCT ON with no ORDER BY in the same query keeps the row of each key DuckDB reaches first' FROM located
WHERE json_type(v, '$.modifiers') = 'ARRAY'
  AND EXISTS (SELECT 1 FROM json_each(json_extract(v, '$.modifiers')) AS m
    WHERE json_extract_string(m.value, '$.type') = 'DISTINCT_MODIFIER'
      AND coalesce(json_array_length(m.value, '$.distinct_on_targets'), 0) > 0)
  AND NOT EXISTS (SELECT 1 FROM json_each(json_extract(v, '$.modifiers')) AS m
    WHERE json_extract_string(m.value, '$.type') = 'ORDER_MODIFIER' AND json_array_length(m.value, '$.orders') > 0)
UNION ALL
SELECT fn || '()' || loc || ' takes an argument that is not a CAST to a type other than FLOAT or DOUBLE ('
    || CASE WHEN json_extract_string(v, '$.children[0].class') = 'CAST' THEN coalesce(json_extract_string(v, '$.children[0].cast_type.id'), '?') ELSE 'no CAST' END
    || '); a FLOAT or DOUBLE histogram merges NaN and -0.0 by the order rows reach it' FROM located
WHERE class IN ('FUNCTION', 'WINDOW') AND list_contains(histograms(), fn) AND json_array_length(v, '$.children') = 1
  AND (json_extract_string(v, '$.children[0].class') IS DISTINCT FROM 'CAST'
    OR coalesce(json_extract_string(v, '$.children[0].cast_type.id'), 'UNBOUND') IN ('FLOAT', 'DOUBLE', 'UNBOUND'))
UNION ALL
SELECT fn || '()' || loc || ' takes bins that read a column, so each group''s bins are those of the first row that reaches it' FROM located
WHERE class IN ('FUNCTION', 'WINDOW') AND list_contains(histograms(), fn) AND json_array_length(v, '$.children') >= 2
  AND EXISTS (SELECT 1 FROM json_tree(json_extract(v, '$.children[1]')) AS c
    WHERE c.type = 'OBJECT' AND json_extract_string(c.value, '$.class') = 'COLUMN_REF')
UNION ALL
SELECT fn || loc || ' is refused: a macro over string_agg with no ORDER BY' FROM located
WHERE class IN ('FUNCTION', 'WINDOW') AND list_contains(refused_functions(), fn)
UNION ALL
SELECT fn || '()' || loc || ' sorts against the session''s default_order' FROM located
WHERE class = 'FUNCTION' AND list_contains(reverse_sorts(), fn)
UNION ALL
SELECT fn || '()' || loc || ' depends on when, where or in which session the query runs' FROM located
WHERE class IN ('FUNCTION', 'WINDOW') AND list_contains(unstable_functions(), fn)
UNION ALL
SELECT fn || '()' || loc || ' reads the session''s catalog, settings or storage' FROM located
WHERE class IN ('FUNCTION', 'WINDOW') AND (starts_with(fn, 'duckdb_') OR starts_with(fn, 'pragma_'))
UNION ALL
SELECT fn || '()' || loc || ' runs SQL text the discipline cannot read' FROM located
WHERE class = 'FUNCTION' AND list_contains(sql_text_functions(), fn)
UNION ALL
SELECT 'age()' || loc || ' with one argument subtracts from today''s midnight' FROM located
WHERE class = 'FUNCTION' AND fn = 'age' AND coalesce(json_array_length(v, '$.children'), 0) = 1
UNION ALL
SELECT json_extract_string(v, '$.column_names[#-1]') || loc || ' is a SQL value keyword; DuckDB binds it to a clock or session function unless a column of that name is in scope' FROM located
WHERE class = 'COLUMN_REF' AND list_contains(value_keywords(), lower(json_extract_string(v, '$.column_names[#-1]')))
UNION ALL
SELECT 'USING SAMPLE or TABLESAMPLE draws rows at random' FROM located
WHERE coalesce(json_type(v, '$.sample'), 'NULL') <> 'NULL';
