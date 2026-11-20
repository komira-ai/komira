-- order: rows
-- agg count over a DECIMAL(12,2) column, allnull rows
SELECT v, count(*) AS n FROM t_allnull GROUP BY v
