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
    -- An ORDER BY on the outermost query.
    ('no order', 'SELECT id FROM t', 'its outermost query has no ORDER BY'),
    ('limit without order', 'SELECT id FROM t LIMIT 2', 'its outermost query has no ORDER BY'),
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
    ('json_group_array', 'SELECT json_group_array(id) AS j FROM t ORDER BY j ASC NULLS LAST', 'json_group_array at byte 7 is refused: a macro over string_agg with no ORDER BY');

CREATE TABLE got AS
SELECT p.name, p.want, coalesce((SELECT string_agg(offence, '; ' ORDER BY offence) FROM oracle_offences(p.q)), '') AS got
FROM planted p;
COPY (SELECT name, got FROM got ORDER BY name ASC) TO 'discipline.tsv' (FORMAT csv, DELIMITER '\t', HEADER true);
SELECT CASE WHEN count(*) > 0 THEN error('oracle discipline: ' || string_agg(name || ': listed [' || got || '], want [' || want || ']', ' | ' ORDER BY name)) END
FROM got WHERE got <> want;
SELECT CASE WHEN count(*) = 0 THEN error('oracle discipline: no planted case ran') END FROM got;
