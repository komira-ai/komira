-- order: rows
-- agg count col 0key over a TIMESTAMP_MS column, full rows
SELECT count(v) AS c FROM t_full
