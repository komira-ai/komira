-- order: rows
-- agg stddev 0key over a BIGINT column, nulls rows
SELECT stddev_samp(v) AS s FROM t_nulls
