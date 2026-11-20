-- order: rows
-- agg var 0key over a BIGINT column, allnull rows
SELECT var_samp(v) AS s FROM t_allnull
