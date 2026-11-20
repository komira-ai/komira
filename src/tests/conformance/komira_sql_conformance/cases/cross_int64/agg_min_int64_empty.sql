-- order: rows
-- agg min over a BIGINT column, empty rows
SELECT g, min(v) AS m FROM t_empty GROUP BY g
