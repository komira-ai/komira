-- order: rows
-- agg count over a DECIMAL(12,2) column, empty rows
SELECT v, count(*) AS n FROM t_empty GROUP BY v
