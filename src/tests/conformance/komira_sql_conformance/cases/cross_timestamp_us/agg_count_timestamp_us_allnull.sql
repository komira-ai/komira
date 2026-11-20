-- order: rows
-- agg count over a TIMESTAMP column, allnull rows
SELECT v, count(*) AS n FROM t_allnull GROUP BY v
