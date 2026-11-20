-- order: rows
-- agg avg mean 0key over a DECIMAL(12,2) column, allnull rows
SELECT avg(v) AS a, mean(v) AS m FROM t_allnull
