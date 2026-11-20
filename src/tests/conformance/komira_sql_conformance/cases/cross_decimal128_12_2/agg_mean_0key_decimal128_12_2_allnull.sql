-- order: rows
-- agg mean 0key over a DECIMAL(12,2) column, allnull rows
SELECT avg(v) AS a FROM t_allnull
