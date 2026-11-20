-- order: rows
-- agg stddev grouped over a BIGINT column, empty rows
SELECT g, stddev_samp(v) AS s FROM t_empty GROUP BY g
