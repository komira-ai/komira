-- order: rows
-- agg max over a TINYINT column, full rows
SELECT g, max(v) AS m FROM t_full GROUP BY g
