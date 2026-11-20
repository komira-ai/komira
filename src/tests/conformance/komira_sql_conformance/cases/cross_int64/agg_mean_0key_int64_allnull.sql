-- order: rows
-- agg mean 0key over a BIGINT column, allnull rows
SELECT avg(v) AS a FROM t_allnull
