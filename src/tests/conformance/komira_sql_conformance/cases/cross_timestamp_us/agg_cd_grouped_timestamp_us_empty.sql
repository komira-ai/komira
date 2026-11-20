-- order: rows
-- agg cd grouped over a TIMESTAMP column, empty rows
SELECT g, count(DISTINCT v) AS n FROM t_empty GROUP BY g
