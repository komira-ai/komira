-- order: rows
-- agg sum 0key over a BIGINT column, allnull rows
SELECT sum(v) AS s FROM t_allnull
