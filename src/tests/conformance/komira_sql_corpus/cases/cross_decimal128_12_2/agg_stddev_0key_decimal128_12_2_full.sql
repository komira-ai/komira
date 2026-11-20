-- order: rows
-- agg stddev 0key over a DECIMAL(12,2) column, full rows
SELECT stddev_samp(v) AS s FROM t_full
