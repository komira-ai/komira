-- order: rows
-- agg cd grouped over a TIMESTAMP column, nulls rows
SELECT g, count(DISTINCT v) AS n FROM t_nulls GROUP BY g
