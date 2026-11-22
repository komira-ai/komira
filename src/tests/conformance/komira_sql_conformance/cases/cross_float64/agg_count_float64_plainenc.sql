-- order: rows
-- agg count over a DOUBLE column; same rows as t_full
SELECT v, count(*) AS n FROM t_full GROUP BY v
