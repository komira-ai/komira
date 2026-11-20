-- order: rows
-- agg count col 0key over a BOOLEAN column, allnull rows
SELECT count(v) AS c FROM t_allnull
