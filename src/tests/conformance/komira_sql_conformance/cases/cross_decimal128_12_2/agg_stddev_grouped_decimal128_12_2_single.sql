-- order: rows
-- agg stddev grouped over a DECIMAL(12,2) column, single rows
SELECT g, stddev_samp(v) AS s FROM t_single GROUP BY g
