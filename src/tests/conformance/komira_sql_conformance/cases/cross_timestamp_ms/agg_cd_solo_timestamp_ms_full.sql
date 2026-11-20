-- order: rows
-- agg cd solo over a TIMESTAMP_MS column, full rows
SELECT count(DISTINCT v) AS n FROM t_full
