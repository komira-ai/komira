-- order: rows
-- agg median 0key over a BOOLEAN column, empty rows
SELECT median(v) AS m FROM t_empty
