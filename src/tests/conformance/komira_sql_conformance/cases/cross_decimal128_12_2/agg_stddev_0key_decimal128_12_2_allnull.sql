-- order: rows
-- agg stddev 0key over a DECIMAL(12,2) column, allnull rows
SELECT stddev_samp(v) AS s FROM t_allnull
