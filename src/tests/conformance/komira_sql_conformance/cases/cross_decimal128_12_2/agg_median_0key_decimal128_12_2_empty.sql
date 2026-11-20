-- order: rows
-- agg median 0key over a DECIMAL(12,2) column, empty rows
SELECT median(v) AS m FROM t_empty
