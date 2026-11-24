-- Aggregates over no row: count 0, the others NULL.
SELECT count(*) AS n, sum(i32) AS s, min(v) AS m FROM nulls WHERE id < 0 ORDER BY n ASC NULLS LAST
