-- order: rows
-- agg stddev grouped over a DOUBLE column, full rows
SELECT g, stddev_samp(v) AS s FROM t_full GROUP BY g
