-- order: rows
-- agg cd solo over a TIMESTAMPTZ column, full rows
SELECT count(DISTINCT v) AS n FROM t_full
