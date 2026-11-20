-- order: rows
-- agg count over a VARCHAR column; same rows as t_full
SELECT v, count(*) AS n FROM t_full GROUP BY v
