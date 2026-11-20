-- order: rows
-- agg count col 0key over a TIMESTAMPTZ column, full rows
SELECT count(v) AS c FROM t_full
