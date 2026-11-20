-- order: rows
-- agg min over a BIGINT column, single rows
SELECT g, min(v) AS m FROM t_single GROUP BY g
