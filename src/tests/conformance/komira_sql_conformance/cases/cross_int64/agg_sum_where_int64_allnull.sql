-- order: rows
-- agg sum where over a BIGINT column, allnull rows
SELECT sum(v) AS s FROM t_allnull WHERE k > 2
