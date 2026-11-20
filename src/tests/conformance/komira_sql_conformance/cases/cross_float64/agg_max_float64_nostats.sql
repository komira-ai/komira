-- order: rows
-- agg max over a DOUBLE column; same rows as t_full
SELECT g, max(v) AS m FROM t_full GROUP BY g
