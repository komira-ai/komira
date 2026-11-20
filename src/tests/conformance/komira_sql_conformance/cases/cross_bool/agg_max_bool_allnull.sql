-- order: rows
-- agg max over a BOOLEAN column, allnull rows
SELECT g, max(v) AS m FROM t_allnull GROUP BY g
