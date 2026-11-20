-- order: rows
-- agg cd grouped over a TIMESTAMP_MS column, full rows
SELECT g, count(DISTINCT v) AS n FROM t_full GROUP BY g
