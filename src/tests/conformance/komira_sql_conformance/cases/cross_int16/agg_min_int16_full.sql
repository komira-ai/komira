-- order: rows
-- agg min over a SMALLINT column, full rows
SELECT g, min(v) AS m FROM t_full GROUP BY g
