-- order: rows
-- agg count over a DECIMAL(12,2) column, single rows
SELECT v, count(*) AS n FROM t_single GROUP BY v
