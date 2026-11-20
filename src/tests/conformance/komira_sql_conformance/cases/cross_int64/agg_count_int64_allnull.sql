-- order: rows
-- agg count over a BIGINT column, allnull rows
SELECT v, count(*) AS n FROM t_allnull GROUP BY v
