-- order: rows
-- agg median 0key over a TIMESTAMP_MS column, full rows
SELECT median(v) AS m FROM t_full
