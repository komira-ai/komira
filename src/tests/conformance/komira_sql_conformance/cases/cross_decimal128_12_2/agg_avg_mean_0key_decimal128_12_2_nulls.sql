-- order: rows
-- agg avg mean 0key over a DECIMAL(12,2) column, nulls rows
SELECT avg(v) AS a, mean(v) AS m FROM t_nulls
