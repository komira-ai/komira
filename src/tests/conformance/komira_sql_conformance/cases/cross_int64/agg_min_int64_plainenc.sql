-- order: rows
-- agg min over a BIGINT column; same rows as t_full
SELECT g, min(v) AS m FROM t_full GROUP BY g
