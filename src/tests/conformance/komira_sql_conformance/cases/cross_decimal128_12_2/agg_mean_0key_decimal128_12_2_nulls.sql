-- order: rows
-- agg mean 0key over a DECIMAL(12,2) column, nulls rows
SELECT avg(v) AS a FROM t_nulls
