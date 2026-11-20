-- order: rows
-- agg stddev 0key over a DECIMAL(12,2) column, nulls rows
SELECT stddev_samp(v) AS s FROM t_nulls
