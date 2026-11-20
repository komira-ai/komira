-- order: rows
-- agg var 0key over a DECIMAL(12,2) column, empty rows
SELECT var_samp(v) AS s FROM t_empty
