-- order: rows
-- agg count over a DATE column, full rows
SELECT v, count(*) AS n FROM t_full GROUP BY v
