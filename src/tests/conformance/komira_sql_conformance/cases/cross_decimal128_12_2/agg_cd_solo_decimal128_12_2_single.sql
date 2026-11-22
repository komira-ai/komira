-- order: rows
-- agg cd solo over a DECIMAL(12,2) column, single rows
SELECT count(DISTINCT v) AS n FROM t_single
