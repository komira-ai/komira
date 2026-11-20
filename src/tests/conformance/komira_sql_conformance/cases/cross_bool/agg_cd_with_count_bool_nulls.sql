-- order: rows
-- agg cd with count over a BOOLEAN column, nulls rows
SELECT count(*) AS c, count(DISTINCT v) AS n FROM t_nulls
