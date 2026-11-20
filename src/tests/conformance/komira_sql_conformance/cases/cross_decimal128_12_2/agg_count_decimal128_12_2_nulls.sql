-- order: rows
-- agg count over a DECIMAL(12,2) column, nulls rows
SELECT v, count(*) AS n FROM t_nulls GROUP BY v
