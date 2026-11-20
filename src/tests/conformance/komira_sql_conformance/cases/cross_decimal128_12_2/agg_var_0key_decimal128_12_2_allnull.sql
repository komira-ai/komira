-- order: rows
-- agg var 0key over a DECIMAL(12,2) column, allnull rows
SELECT var_samp(v) AS s FROM t_allnull
