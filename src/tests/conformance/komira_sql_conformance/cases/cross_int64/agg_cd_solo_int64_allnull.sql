-- order: rows
-- agg cd solo over a BIGINT column, allnull rows
SELECT count(DISTINCT v) AS n FROM t_allnull
