-- order: rows
-- agg count over a VARCHAR column, empty rows
SELECT v, count(*) AS n FROM t_empty GROUP BY v
