-- order: rows
-- agg count col 0key over a TIMESTAMP column, allnull rows
SELECT count(v) AS c FROM t_allnull
