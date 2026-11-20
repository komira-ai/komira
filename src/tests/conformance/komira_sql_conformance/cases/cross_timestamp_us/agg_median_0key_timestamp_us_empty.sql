-- order: rows
-- agg median 0key over a TIMESTAMP column, empty rows
SELECT median(v) AS m FROM t_empty
