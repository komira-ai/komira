-- order: rows
-- agg cd grouped over a VARCHAR column, allnull rows
SELECT g, count(DISTINCT v) AS n FROM t_allnull GROUP BY g
