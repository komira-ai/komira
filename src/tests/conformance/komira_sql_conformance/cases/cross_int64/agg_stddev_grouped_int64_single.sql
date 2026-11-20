-- order: rows
-- agg stddev grouped over a BIGINT column, single rows
SELECT g, stddev_samp(v) AS s FROM t_single GROUP BY g
