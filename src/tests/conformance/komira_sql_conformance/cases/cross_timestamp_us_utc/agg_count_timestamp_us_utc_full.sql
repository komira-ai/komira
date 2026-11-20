-- order: rows
-- agg count over a TIMESTAMPTZ column, full rows
SELECT v, count(*) AS n FROM t_full GROUP BY v
