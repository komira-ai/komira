-- order: rows
-- agg stddev grouped over a BIGINT column, nulls rows
SELECT g, stddev_samp(v) AS s FROM t_nulls GROUP BY g
