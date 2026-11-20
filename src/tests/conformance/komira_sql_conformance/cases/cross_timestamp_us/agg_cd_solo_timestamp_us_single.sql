-- order: rows
-- agg cd solo over a TIMESTAMP column, single rows
SELECT count(DISTINCT v) AS n FROM t_single
