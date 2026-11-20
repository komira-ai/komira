-- order: rows
-- agg stddev 0key over a DOUBLE column, full rows
SELECT stddev_samp(v) AS s FROM t_full
