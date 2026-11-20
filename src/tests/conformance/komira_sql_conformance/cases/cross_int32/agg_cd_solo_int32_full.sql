-- order: rows
-- agg cd solo over a INTEGER column, full rows
SELECT count(DISTINCT v) AS n FROM t_full
