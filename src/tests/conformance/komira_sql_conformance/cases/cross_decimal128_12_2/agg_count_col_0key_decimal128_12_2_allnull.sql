-- order: rows
-- agg count col 0key over a DECIMAL(12,2) column, allnull rows
SELECT count(v) AS c FROM t_allnull
