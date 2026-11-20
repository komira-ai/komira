-- order: rows
-- agg count over a VARCHAR column, allnull rows
SELECT v, count(*) AS n FROM t_allnull GROUP BY v
