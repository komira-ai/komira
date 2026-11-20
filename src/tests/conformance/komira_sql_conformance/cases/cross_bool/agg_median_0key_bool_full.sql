-- order: rows
-- agg median 0key over a BOOLEAN column, full rows
SELECT median(v) AS m FROM t_full
