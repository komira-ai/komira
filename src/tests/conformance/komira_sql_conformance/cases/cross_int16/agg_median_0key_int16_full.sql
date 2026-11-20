-- order: rows
-- agg median 0key over a SMALLINT column, full rows
SELECT median(v) AS m FROM t_full
