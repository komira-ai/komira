-- order: rows
-- agg min over a TINYINT column, full rows
SELECT g, min(v) AS m FROM t_full GROUP BY g
