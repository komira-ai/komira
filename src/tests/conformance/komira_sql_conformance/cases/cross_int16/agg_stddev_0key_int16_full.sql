-- order: rows
-- agg stddev 0key over a SMALLINT column, full rows
SELECT stddev_samp(v) AS s FROM t_full
