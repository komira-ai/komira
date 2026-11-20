-- order: rows
-- agg max over a DECIMAL(12,2) column, allnull rows
SELECT g, max(v) AS m FROM t_allnull GROUP BY g
