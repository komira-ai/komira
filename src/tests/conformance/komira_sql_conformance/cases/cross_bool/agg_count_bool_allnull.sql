-- order: rows
-- agg count over a BOOLEAN column, allnull rows
SELECT v, count(*) AS n FROM t_allnull GROUP BY v
