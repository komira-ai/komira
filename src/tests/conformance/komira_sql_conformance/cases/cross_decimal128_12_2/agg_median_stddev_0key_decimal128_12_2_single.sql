-- order: rows
-- agg median stddev 0key over a DECIMAL(12,2) column, single rows
SELECT median(v) AS m, stddev_samp(v) AS s FROM t_single
