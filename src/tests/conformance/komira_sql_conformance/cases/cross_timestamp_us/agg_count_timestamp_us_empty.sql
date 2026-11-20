-- order: rows
-- agg count over a TIMESTAMP column, empty rows
SELECT v, count(*) AS n FROM t_empty GROUP BY v
