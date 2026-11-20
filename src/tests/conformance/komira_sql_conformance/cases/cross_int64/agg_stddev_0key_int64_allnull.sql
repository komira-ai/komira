-- order: rows
-- agg stddev 0key over a BIGINT column, allnull rows
SELECT stddev_samp(v) AS s FROM t_allnull
