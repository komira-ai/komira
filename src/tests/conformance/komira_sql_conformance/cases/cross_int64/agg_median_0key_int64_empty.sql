-- order: rows
-- agg median 0key over a BIGINT column, empty rows
SELECT median(v) AS m FROM t_empty
