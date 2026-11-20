-- order: rows
-- agg min over a VARCHAR column, empty rows
SELECT g, min(v) AS m FROM t_empty GROUP BY g
