-- discipline_check: oracle_offences (discipline.sql) over planted cases,
-- each breaking one rule (or none), against the offences it must list,
-- exactly, joined by '; ' in order ('' for a case it must accept). A rule
-- that stops refusing, or starts refusing what is right, fails this target
-- with every disagreement listed. DuckDB only parses these: no table named
-- in them exists.
CREATE TABLE planted (name VARCHAR, q VARCHAR, want VARCHAR);
INSERT INTO planted VALUES
    -- Accepted.
    ('ordered', 'SELECT id FROM t ORDER BY id ASC NULLS LAST', ''),
    ('ordered aggregate', 'SELECT string_agg(s, '','' ORDER BY s DESC NULLS FIRST) AS l FROM t ORDER BY l ASC NULLS LAST', ''),
    ('ordered window', 'SELECT row_number() OVER (PARTITION BY k ORDER BY id ASC NULLS LAST) AS r FROM t ORDER BY r ASC NULLS LAST', ''),
    ('order-free aggregates', 'SELECT count(*) AS n, sum(v) AS s, min(v) AS lo FROM t ORDER BY n ASC NULLS LAST', ''),
    ('set operation ordered', 'SELECT id FROM t UNION ALL SELECT id FROM u ORDER BY id DESC NULLS FIRST', ''),
    ('limit over order', 'SELECT id FROM t ORDER BY id ASC NULLS LAST LIMIT 2', ''),
    -- One SELECT.
    ('two statements', 'SELECT 1 AS a ORDER BY a ASC NULLS LAST; SELECT 2 AS b ORDER BY b ASC NULLS LAST', 'holds 2 statements, not one SELECT'),
    ('not a select', 'COPY t TO ''x.csv''', 'is not one SELECT: Only SELECT statements can be serialized to json!'),
    ('syntax error', 'SELEC 1', 'is not one SELECT: syntax error at or near "SELEC"'),
    ('empty text', '', 'holds 0 statements, not one SELECT; its outermost query has no ORDER BY'),
    -- An ORDER BY on the outermost query.
    ('no order', 'SELECT id FROM t', 'its outermost query has no ORDER BY'),
    ('limit without order', 'SELECT id FROM t LIMIT 2', 'a LIMIT or OFFSET with no ORDER BY in the same query keeps the rows DuckDB reaches first; its outermost query has no ORDER BY'),
    ('order only inside', 'SELECT * FROM (SELECT id FROM t ORDER BY id ASC NULLS LAST) AS s', 'its outermost query has no ORDER BY'),
    ('set operation unordered', 'SELECT id FROM t UNION ALL SELECT id FROM u', 'its outermost query has no ORDER BY'),
    -- Direction and NULL placement, at every ORDER BY.
    ('no direction', 'SELECT id FROM t ORDER BY id NULLS LAST', 'the ORDER BY key at byte 26 states no ASC or DESC'),
    ('no placement', 'SELECT id FROM t ORDER BY id ASC', 'the ORDER BY key at byte 26 states no NULLS FIRST or NULLS LAST'),
    ('second key bare', 'SELECT id FROM t ORDER BY id ASC NULLS LAST, v', 'the ORDER BY key at byte 45 states no ASC or DESC; the ORDER BY key at byte 45 states no NULLS FIRST or NULLS LAST'),
    ('inner order', 'SELECT * FROM (SELECT id FROM t ORDER BY id DESC LIMIT 1) AS s ORDER BY id ASC NULLS LAST', 'the ORDER BY key at byte 41 states no NULLS FIRST or NULLS LAST'),
    ('order in a CTE', 'WITH c AS (SELECT id FROM t ORDER BY id ASC LIMIT 3) SELECT id FROM c ORDER BY id ASC NULLS LAST', 'the ORDER BY key at byte 37 states no NULLS FIRST or NULLS LAST'),
    ('window order', 'SELECT rank() OVER (ORDER BY id) AS r FROM t ORDER BY r ASC NULLS LAST', 'the ORDER BY key at byte 29 states no ASC or DESC; the ORDER BY key at byte 29 states no NULLS FIRST or NULLS LAST'),
    ('aggregate order', 'SELECT string_agg(s, '','' ORDER BY s DESC) AS l FROM t ORDER BY l ASC NULLS LAST', 'the ORDER BY key at byte 34 states no NULLS FIRST or NULLS LAST'),
    -- Order-sensitive aggregates and position-reading windows.
    ('list unordered', 'SELECT list(id) AS l FROM t ORDER BY l ASC NULLS LAST', 'the aggregate list at byte 7 has no ORDER BY of its own, so its answer depends on the order rows reach it'),
    ('first unordered', 'SELECT k, first(v) AS f FROM t GROUP BY k ORDER BY k ASC NULLS LAST', 'the aggregate first at byte 10 has no ORDER BY of its own, so its answer depends on the order rows reach it'),
    ('arg_max unordered', 'SELECT arg_max(id, v) AS a FROM t ORDER BY a ASC NULLS LAST', 'the aggregate arg_max at byte 7 has no ORDER BY of its own, so its answer depends on the order rows reach it'),
    ('lag unordered', 'SELECT lag(id) OVER (PARTITION BY k) AS p FROM t ORDER BY p ASC NULLS LAST', 'the window function lag at byte 7 has no ORDER BY in its OVER clause or of its own'),
    ('string_agg over all', 'SELECT string_agg(s, '','') OVER () AS l FROM t ORDER BY l ASC NULLS LAST', 'the window function string_agg at byte 7 has no ORDER BY in its OVER clause or of its own'),
    ('json_group_array', 'SELECT json_group_array(id) AS j FROM t ORDER BY j ASC NULLS LAST', 'json_group_array at byte 7 is refused: a macro over string_agg with no ORDER BY'),
    ('list_reverse_sort with placement', 'SELECT list_reverse_sort(l, ''NULLS LAST'') AS r FROM t ORDER BY r ASC NULLS LAST', 'list_reverse_sort() at byte 7 sorts against the session''s default_order'),
    -- A ROWS frame needs an ORDER BY in its OVER clause, whatever the function.
    ('rows frame unordered', 'SELECT count(v) OVER (ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS c FROM t ORDER BY c ASC NULLS LAST', 'the window function count at byte 7 has a ROWS frame and no ORDER BY in its OVER clause, so the frame counts rows in the order they reach it'),
    ('rows frame in a partition', 'SELECT sum(v) OVER (PARTITION BY k ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS c FROM t ORDER BY c ASC NULLS LAST', 'the window function sum at byte 7 has a ROWS frame and no ORDER BY in its OVER clause, so the frame counts rows in the order they reach it'),
    ('rows frame bounded at the start', 'SELECT sum(v) OVER (ROWS BETWEEN 1 PRECEDING AND UNBOUNDED FOLLOWING) AS c FROM t ORDER BY c ASC NULLS LAST', 'the window function sum at byte 7 has a ROWS frame and no ORDER BY in its OVER clause, so the frame counts rows in the order they reach it'),
    ('rows frame bounded at the end', 'SELECT sum(v) OVER (ROWS BETWEEN UNBOUNDED PRECEDING AND 1 FOLLOWING) AS c FROM t ORDER BY c ASC NULLS LAST', 'the window function sum at byte 7 has a ROWS frame and no ORDER BY in its OVER clause, so the frame counts rows in the order they reach it'),
    ('rows frame, the function ordered', 'SELECT first_value(v ORDER BY id ASC NULLS LAST) OVER (ROWS 1 PRECEDING) AS c FROM t ORDER BY c ASC NULLS LAST', 'the window function first_value at byte 7 has a ROWS frame and no ORDER BY in its OVER clause, so the frame counts rows in the order they reach it'),
    ('rows frame of a named window', 'SELECT count(v) OVER w AS c FROM t WINDOW w AS (ROWS 1 PRECEDING) ORDER BY c ASC NULLS LAST', 'the window function count at byte 7 has a ROWS frame and no ORDER BY in its OVER clause, so the frame counts rows in the order they reach it'),
    ('rows frame in a subquery', 'SELECT s FROM (SELECT sum(v) OVER (ROWS BETWEEN CURRENT ROW AND CURRENT ROW) AS s FROM t) AS q ORDER BY s ASC NULLS LAST', 'the window function sum at byte 22 has a ROWS frame and no ORDER BY in its OVER clause, so the frame counts rows in the order they reach it'),
    -- One case per bound kind where only that bound is a ROWS bound.
    ('rows frame from the current row', 'SELECT sum(v) OVER (ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING) AS c FROM t ORDER BY c ASC NULLS LAST', 'the window function sum at byte 7 has a ROWS frame and no ORDER BY in its OVER clause, so the frame counts rows in the order they reach it'),
    ('rows frame from a following row', 'SELECT sum(v) OVER (ROWS BETWEEN 1 FOLLOWING AND UNBOUNDED FOLLOWING) AS c FROM t ORDER BY c ASC NULLS LAST', 'the window function sum at byte 7 has a ROWS frame and no ORDER BY in its OVER clause, so the frame counts rows in the order they reach it'),
    ('rows frame to a preceding row', 'SELECT sum(v) OVER (ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS c FROM t ORDER BY c ASC NULLS LAST', 'the window function sum at byte 7 has a ROWS frame and no ORDER BY in its OVER clause, so the frame counts rows in the order they reach it'),
    ('range frame from the current row', 'SELECT sum(v) OVER (RANGE BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING) AS c FROM t ORDER BY c ASC NULLS LAST', ''),
    ('groups frame unordered', 'SELECT sum(v) OVER (GROUPS BETWEEN 1 PRECEDING AND 1 FOLLOWING) AS c FROM t ORDER BY c ASC NULLS LAST', ''),
    ('rows frame ordered','SELECT sum(v) OVER (ORDER BY id ASC NULLS LAST ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) AS c FROM t ORDER BY c ASC NULLS LAST', ''),
    ('rows frame unbounded', 'SELECT sum(v) OVER (ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS c FROM t ORDER BY c ASC NULLS LAST', ''),
    ('range frame unordered', 'SELECT sum(v) OVER (RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS c FROM t ORDER BY c ASC NULLS LAST', ''),
    -- A LIMIT, an OFFSET or a DISTINCT ON needs an ORDER BY in its own query node.
    ('offset without order', 'SELECT id FROM t OFFSET 2', 'a LIMIT or OFFSET with no ORDER BY in the same query keeps the rows DuckDB reaches first; its outermost query has no ORDER BY'),
    ('limit percent without order', 'SELECT id FROM t LIMIT 50%', 'a LIMIT or OFFSET with no ORDER BY in the same query keeps the rows DuckDB reaches first; its outermost query has no ORDER BY'),
    ('limit after a union', 'SELECT id FROM t UNION ALL SELECT id FROM u LIMIT 2', 'a LIMIT or OFFSET with no ORDER BY in the same query keeps the rows DuckDB reaches first; its outermost query has no ORDER BY'),
    ('limit in a subquery', 'SELECT id FROM (SELECT id FROM t LIMIT 2) AS s ORDER BY id ASC NULLS LAST', 'a LIMIT or OFFSET with no ORDER BY in the same query keeps the rows DuckDB reaches first'),
    ('offset in a subquery', 'SELECT id FROM (SELECT id FROM t OFFSET 2) AS s ORDER BY id ASC NULLS LAST', 'a LIMIT or OFFSET with no ORDER BY in the same query keeps the rows DuckDB reaches first'),
    ('limit in a filter subquery', 'SELECT id FROM t WHERE k IN (SELECT k FROM u LIMIT 1) ORDER BY id ASC NULLS LAST', 'a LIMIT or OFFSET with no ORDER BY in the same query keeps the rows DuckDB reaches first'),
    ('limit in a CTE', 'WITH c AS (SELECT id FROM t LIMIT 3) SELECT id FROM c ORDER BY id ASC NULLS LAST', 'a LIMIT or OFFSET with no ORDER BY in the same query keeps the rows DuckDB reaches first'),
    ('distinct on unordered', 'SELECT DISTINCT ON (k) k, id FROM t', 'DISTINCT ON with no ORDER BY in the same query keeps the row of each key DuckDB reaches first; its outermost query has no ORDER BY'),
    ('distinct on in a subquery', 'SELECT k FROM (SELECT DISTINCT ON (k) k, id FROM t) AS s ORDER BY k ASC NULLS LAST', 'DISTINCT ON with no ORDER BY in the same query keeps the row of each key DuckDB reaches first'),
    ('limit and offset over order', 'SELECT id FROM t ORDER BY id ASC NULLS LAST LIMIT 2 OFFSET 1', ''),
    ('limit in an ordered subquery', 'SELECT id FROM (SELECT id FROM t ORDER BY id DESC NULLS FIRST LIMIT 2) AS s ORDER BY id ASC NULLS LAST', ''),
    ('distinct on ordered', 'SELECT DISTINCT ON (k) k, id FROM t ORDER BY k ASC NULLS LAST, id ASC NULLS LAST', ''),
    ('distinct on ordered by its key', 'SELECT DISTINCT ON (k) k FROM t ORDER BY k ASC NULLS LAST', ''),
    ('plain distinct','SELECT DISTINCT k FROM t ORDER BY k ASC NULLS LAST', ''),
    ('plain distinct in a subquery', 'SELECT k FROM (SELECT DISTINCT k FROM t) AS s ORDER BY k ASC NULLS LAST', ''),
    -- histogram: a one-argument key that is a CAST to a type other than FLOAT or DOUBLE; bins that name no column.
    ('histogram of a column', 'SELECT histogram(f) AS h FROM t ORDER BY h ASC NULLS LAST', 'histogram() at byte 7 takes an argument that is not a CAST to a type other than FLOAT or DOUBLE (no CAST); a FLOAT or DOUBLE histogram merges NaN and -0.0 by the order rows reach it'),
    ('histogram of a double', 'SELECT histogram(CAST(f AS DOUBLE)) AS h FROM t ORDER BY h ASC NULLS LAST', 'histogram() at byte 7 takes an argument that is not a CAST to a type other than FLOAT or DOUBLE (DOUBLE); a FLOAT or DOUBLE histogram merges NaN and -0.0 by the order rows reach it'),
    ('histogram of a float8', 'SELECT histogram(CAST(f AS FLOAT8)) AS h FROM t ORDER BY h ASC NULLS LAST', 'histogram() at byte 7 takes an argument that is not a CAST to a type other than FLOAT or DOUBLE (DOUBLE); a FLOAT or DOUBLE histogram merges NaN and -0.0 by the order rows reach it'),
    ('histogram of a real', 'SELECT histogram(CAST(f AS REAL)) AS h FROM t ORDER BY h ASC NULLS LAST', 'histogram() at byte 7 takes an argument that is not a CAST to a type other than FLOAT or DOUBLE (FLOAT); a FLOAT or DOUBLE histogram merges NaN and -0.0 by the order rows reach it'),
    ('histogram of an unbound type', 'SELECT histogram(CAST(f AS main.f8)) AS h FROM t ORDER BY h ASC NULLS LAST', 'histogram() at byte 7 takes an argument that is not a CAST to a type other than FLOAT or DOUBLE (UNBOUND); a FLOAT or DOUBLE histogram merges NaN and -0.0 by the order rows reach it'),
    ('histogram of a try_cast', 'SELECT histogram(TRY_CAST(s AS DOUBLE)) AS h FROM t ORDER BY h ASC NULLS LAST', 'histogram() at byte 7 takes an argument that is not a CAST to a type other than FLOAT or DOUBLE (DOUBLE); a FLOAT or DOUBLE histogram merges NaN and -0.0 by the order rows reach it'),
    ('histogram as a window', 'SELECT HISTOGRAM(f) OVER () AS h FROM t ORDER BY h ASC NULLS LAST', 'histogram() at byte 7 takes an argument that is not a CAST to a type other than FLOAT or DOUBLE (no CAST); a FLOAT or DOUBLE histogram merges NaN and -0.0 by the order rows reach it'),
    ('histogram of a bigint', 'SELECT histogram(CAST(v AS BIGINT)) AS h FROM t ORDER BY h ASC NULLS LAST', ''),
    ('histogram of a varchar', 'SELECT histogram(CAST(s AS VARCHAR)) AS h FROM t ORDER BY h ASC NULLS LAST', ''),
    ('histogram bins from a column', 'SELECT histogram(id, CASE WHEN id < 3 THEN [1] ELSE [5] END) AS h FROM t ORDER BY h ASC NULLS LAST', 'histogram() at byte 7 takes bins that read a column, so each group''s bins are those of the first row that reaches it'),
    ('histogram_exact bins from a column', 'SELECT histogram_exact(id, [k]) AS h FROM t ORDER BY h ASC NULLS LAST', 'histogram_exact() at byte 7 takes bins that read a column, so each group''s bins are those of the first row that reaches it'),
    ('histogram bins from a subquery', 'SELECT histogram(id, (SELECT [max(k)] FROM u)) AS h FROM t ORDER BY h ASC NULLS LAST', 'histogram() at byte 7 takes bins that read a column, so each group''s bins are those of the first row that reaches it'),
    ('histogram constant bins', 'SELECT histogram(id, [1, 5]) AS h FROM t ORDER BY h ASC NULLS LAST', ''),
    ('histogram bins from a column as a window', 'SELECT histogram(id, [k]) OVER () AS h FROM t ORDER BY h ASC NULLS LAST', 'histogram() at byte 7 takes bins that read a column, so each group''s bins are those of the first row that reaches it'),
    -- The discipline reads the parse only: a call no DuckDB function binds
    -- is left to the binder.
    ('histogram of no argument', 'SELECT histogram() AS h FROM t ORDER BY h ASC NULLS LAST', ''),
    ('json_group_array as a window', 'SELECT json_group_array(id) OVER () AS j FROM t ORDER BY j ASC NULLS LAST', 'json_group_array at byte 7 is refused: a macro over string_agg with no ORDER BY'),
    -- No clock, random draw or session read, wherever the call stands.
    ('random as a tie breaker', 'SELECT a FROM t ORDER BY a ASC NULLS FIRST, random() ASC NULLS LAST', 'random() at byte 44 depends on when, where or in which session the query runs'),
    ('now in a filter', 'SELECT id FROM t WHERE d < now() ORDER BY id ASC NULLS LAST', 'now() at byte 27 depends on when, where or in which session the query runs'),
    ('catalog table function', 'SELECT name FROM duckdb_settings() ORDER BY name ASC NULLS LAST', 'duckdb_settings() at byte 17 reads the session''s catalog, settings or storage'),
    ('pragma function', 'SELECT pragma_version() AS v ORDER BY v ASC NULLS LAST', 'pragma_version() at byte 7 reads the session''s catalog, settings or storage'),
    ('SQL text in FROM', 'SELECT a FROM query(''SELECT random() AS a'') ORDER BY a ASC NULLS LAST', 'query() at byte 14 runs SQL text the discipline cannot read'),
    ('age of one', 'SELECT age(d) AS a FROM t ORDER BY a ASC NULLS LAST', 'age() at byte 7 with one argument subtracts from today''s midnight'),
    ('age of two', 'SELECT age(d, e) AS a FROM t ORDER BY a ASC NULLS LAST', ''),
    ('age of none', 'SELECT age() AS a FROM t ORDER BY a ASC NULLS LAST', ''),
    ('now as a window', 'SELECT now() OVER () AS a FROM t ORDER BY a ASC NULLS LAST', 'now() at byte 7 depends on when, where or in which session the query runs'),
    ('pragma function as a window', 'SELECT pragma_version() OVER () AS v ORDER BY v ASC NULLS LAST', 'pragma_version() at byte 7 reads the session''s catalog, settings or storage'),
    ('quoted value keyword', 'SELECT "current_date" AS d FROM t ORDER BY d ASC NULLS LAST', 'current_date at byte 7 is a SQL value keyword; DuckDB binds it to a clock or session function unless a column of that name is in scope'),
    ('qualified value keyword', 'SELECT t.CURRENT_TIMESTAMP AS d FROM t ORDER BY d ASC NULLS LAST', 'CURRENT_TIMESTAMP at byte 7 is a SQL value keyword; DuckDB binds it to a clock or session function unless a column of that name is in scope'),
    ('using sample', 'SELECT id FROM t USING SAMPLE 2 ORDER BY id ASC NULLS LAST', 'USING SAMPLE or TABLESAMPLE draws rows at random'),
    ('tablesample', 'SELECT id FROM t TABLESAMPLE 10% ORDER BY id ASC NULLS LAST', 'USING SAMPLE or TABLESAMPLE draws rows at random');

-- Every entry of each of discipline.sql's lists, from a copy held here: the
-- lists must equal the copies (an entry added there or here alone fails),
-- and each entry gets a planted case of its own (an entry the rule no
-- longer matches fails), so no entry can be deleted unseen.
CREATE TABLE copies (list VARCHAR, names VARCHAR[], got VARCHAR[]);
INSERT INTO copies VALUES
    ('order_sensitive_aggregates', [
        'first', 'arbitrary', 'last', 'any_value', 'list', 'array_agg', 'string_agg', 'group_concat', 'listagg',
        'arg_min', 'arg_max', 'arg_min_null', 'arg_max_null', 'argmin', 'argmax', 'min_by', 'max_by',
        'mode', 'approx_top_k', 'approx_quantile', 'reservoir_quantile'], order_sensitive_aggregates()),
    ('positional_windows', [
        'row_number', 'ntile', 'lead', 'lag', 'first_value', 'last_value', 'nth_value', 'fill'], positional_windows()),
    ('refused_functions', ['json_group_array', 'json_group_object', 'json_group_structure'], refused_functions()),
    ('reverse_sorts', ['list_reverse_sort', 'array_reverse_sort'], reverse_sorts()),
    ('histograms', ['histogram', 'histogram_exact'], histograms()),
    ('unstable_functions', [
        'current_database', 'current_date', 'current_schema', 'current_schemas', 'get_current_time',
        'get_current_timestamp', 'in_search_path', 'now', 'today', 'transaction_timestamp', 'txid_current',
        'current_connection_id', 'current_query', 'current_query_id', 'current_transaction_id', 'currval',
        'gen_random_uuid', 'nextval', 'random', 'setseed', 'sleep_ms', 'stats', 'uuid', 'uuidv4', 'uuidv7', 'write_log',
        'current_localtime', 'current_localtimestamp', 'current_setting', 'getvariable',
        'json_serialize_plan', 'json_serialize_sql', 'json_deserialize_sql', 'make_type',
        'parse_duckdb_log_message', 'st_setcrs', 'version', 'vector_type',
        'current_time', 'current_timestamp', 'localtime', 'localtimestamp',
        'ago', 'current_catalog', 'format_type', 'get_block_size', 'pg_conf_load_time', 'pg_get_constraintdef',
        'pg_get_viewdef', 'pg_postmaster_start_time', 'pg_sleep'], unstable_functions()),
    ('sql_text_functions', ['query', 'query_table', 'json_execute_serialized_sql'], sql_text_functions()),
    ('value_keywords', [
        'current_catalog', 'current_date', 'current_role', 'current_schema', 'current_time', 'current_timestamp',
        'current_user', 'localtime', 'localtimestamp', 'session_user', 'user'], value_keywords());
SELECT CASE WHEN count(*) > 0 THEN error('oracle discipline: ' || string_agg(list || '() is not the copy discipline_check.sql holds', '; ' ORDER BY list)) END
FROM copies WHERE list_sort(names) IS DISTINCT FROM list_sort(got);
-- unstable_functions() against the pinned DuckDB itself: every scalar or
-- aggregate it marks VOLATILE or CONSISTENT_WITHIN_QUERY, but error and the
-- duckdb_*/pragma_* names the discipline refuses by prefix, must be listed,
-- so a DuckDB bump that adds one fails here.
SELECT CASE WHEN count(*) > 0 THEN error('oracle discipline: unstable_functions() lacks what this DuckDB marks VOLATILE or CONSISTENT_WITHIN_QUERY: ' || string_agg(name, ', ' ORDER BY name)) END
FROM (SELECT DISTINCT function_name AS name FROM duckdb_functions()
    WHERE function_type IN ('scalar', 'aggregate') AND stability IN ('VOLATILE', 'CONSISTENT_WITHIN_QUERY')
      AND function_name <> 'error' AND NOT starts_with(function_name, 'duckdb_') AND NOT starts_with(function_name, 'pragma_')
      AND NOT list_contains(unstable_functions(), function_name));
INSERT INTO planted
SELECT list || ' ' || fn,
    CASE list
        WHEN 'positional_windows' THEN 'SELECT ' || fn || '(v) OVER () AS a FROM t ORDER BY a ASC NULLS LAST'
        WHEN 'unstable_functions' THEN 'SELECT ' || fn || '() AS a FROM t ORDER BY a ASC NULLS LAST'
        WHEN 'value_keywords' THEN 'SELECT ' || fn || ' AS a FROM t ORDER BY a ASC NULLS LAST'
        ELSE 'SELECT ' || fn || '(v) AS a FROM t ORDER BY a ASC NULLS LAST' END,
    CASE list
        WHEN 'order_sensitive_aggregates' THEN 'the aggregate ' || fn || ' at byte 7 has no ORDER BY of its own, so its answer depends on the order rows reach it'
        WHEN 'positional_windows' THEN 'the window function ' || fn || ' at byte 7 has no ORDER BY in its OVER clause or of its own'
        WHEN 'refused_functions' THEN fn || ' at byte 7 is refused: a macro over string_agg with no ORDER BY'
        WHEN 'reverse_sorts' THEN fn || '() at byte 7 sorts against the session''s default_order'
        WHEN 'histograms' THEN fn || '() at byte 7 takes an argument that is not a CAST to a type other than FLOAT or DOUBLE (no CAST); a FLOAT or DOUBLE histogram merges NaN and -0.0 by the order rows reach it'
        WHEN 'unstable_functions' THEN fn || '() at byte 7 depends on when, where or in which session the query runs'
        WHEN 'sql_text_functions' THEN fn || '() at byte 7 runs SQL text the discipline cannot read'
        ELSE fn || ' at byte 7 is a SQL value keyword; DuckDB binds it to a clock or session function unless a column of that name is in scope' END
FROM (SELECT list, unnest(names) AS fn FROM copies);

CREATE TABLE got AS
SELECT p.name, p.want, coalesce((SELECT string_agg(offence, '; ' ORDER BY offence) FROM oracle_offences(p.q)), '') AS got
FROM planted p;
COPY (SELECT name, got FROM got ORDER BY name ASC) TO 'discipline.tsv' (FORMAT csv, DELIMITER '\t', HEADER true);
SELECT CASE WHEN count(*) > 0 THEN error('oracle discipline: ' || string_agg(name || ': listed [' || got || '], want [' || want || ']', ' | ' ORDER BY name)) END
FROM got WHERE got <> want;
SELECT CASE WHEN count(*) = 0 THEN error('oracle discipline: no planted case ran') END FROM got;
