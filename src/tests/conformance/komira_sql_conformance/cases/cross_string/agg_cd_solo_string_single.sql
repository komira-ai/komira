-- order: rows
-- agg cd solo over a VARCHAR column, single rows
SELECT count(DISTINCT v) AS n FROM t_single
