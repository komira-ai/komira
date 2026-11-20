-- order: rows
-- agg min over a FLOAT column, full rows
SELECT g, min(v) AS m FROM t_full GROUP BY g
