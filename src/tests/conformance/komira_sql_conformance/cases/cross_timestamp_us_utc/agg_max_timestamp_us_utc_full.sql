-- order: rows
-- agg max over a TIMESTAMPTZ column, full rows
SELECT g, max(v) AS m FROM t_full GROUP BY g
