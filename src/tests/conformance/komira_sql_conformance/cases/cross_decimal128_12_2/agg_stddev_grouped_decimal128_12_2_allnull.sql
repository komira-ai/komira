-- order: rows
-- agg stddev grouped over a DECIMAL(12,2) column, allnull rows
SELECT g, stddev_samp(v) AS s FROM t_allnull GROUP BY g
