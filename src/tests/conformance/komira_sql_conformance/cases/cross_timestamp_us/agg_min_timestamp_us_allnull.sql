-- order: rows
-- agg min over a TIMESTAMP column, allnull rows
SELECT g, min(v) AS m FROM t_allnull GROUP BY g
