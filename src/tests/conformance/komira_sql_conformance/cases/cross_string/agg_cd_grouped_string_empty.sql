-- order: rows
-- agg cd grouped over a VARCHAR column, empty rows
SELECT g, count(DISTINCT v) AS n FROM t_empty GROUP BY g
