-- order: rows
-- agg cd solo over a VARCHAR column, full rows
SELECT count(DISTINCT v) AS n FROM t_full
