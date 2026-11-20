-- order: rows
-- agg count over a BOOLEAN column, nulls rows
SELECT v, count(*) AS n FROM t_nulls GROUP BY v
