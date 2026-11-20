-- order: rows
-- agg min over a DECIMAL(12,2) column, allnull rows
SELECT g, min(v) AS m FROM t_allnull GROUP BY g
