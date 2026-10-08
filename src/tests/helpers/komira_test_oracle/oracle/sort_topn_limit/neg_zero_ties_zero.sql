-- order: total
-- not null: id
-- Twin of the HAND case: f ASC, id ASC with the default placement, NULLS
-- LAST (§4.1), stated. -0.0 and 0.0 tie (§4.4), so id orders ids 2, 3, 6.
-- The key is f + 0.0, not f: DuckDB 1.5.6 returns a float sort key column
-- with -0.0 turned into 0.0 (ORDER BY f gives id 3 the value 0.0), while
-- a sort keeps its input values. f + 0.0 orders exactly as f does (it maps
-- only -0.0, to the 0.0 it ties with), and f is returned untouched.
SELECT id, a, b, f
FROM sort_rows
ORDER BY f + CAST(0.0 AS DOUBLE) ASC NULLS LAST, id ASC NULLS LAST
