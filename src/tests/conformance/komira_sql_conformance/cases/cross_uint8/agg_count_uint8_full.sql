-- order: rows
-- agg count over a UTINYINT column, full rows
SELECT v, count(*) AS n FROM t_full GROUP BY v
