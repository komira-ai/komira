-- order: rows
-- agg median 0key over a BLOB column, full rows
SELECT median(v) AS m FROM t_full
