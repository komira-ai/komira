-- order: rows
-- agg max over a VARCHAR column, empty rows
SELECT g, max(v) AS m FROM t_empty GROUP BY g
