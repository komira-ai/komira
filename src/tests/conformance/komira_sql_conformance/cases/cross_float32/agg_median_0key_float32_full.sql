-- order: rows
-- agg median 0key over a FLOAT column, full rows
SELECT median(v) AS m FROM t_full
