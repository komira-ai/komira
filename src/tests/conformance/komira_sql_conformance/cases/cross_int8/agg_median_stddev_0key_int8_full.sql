-- order: rows
-- agg median stddev 0key over a TINYINT column, full rows
SELECT median(v) AS m, stddev_samp(v) AS s FROM t_full
