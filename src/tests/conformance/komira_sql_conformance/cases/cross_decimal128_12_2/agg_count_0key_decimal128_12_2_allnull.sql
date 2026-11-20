-- order: rows
-- agg count 0key over a DECIMAL(12,2) column, allnull rows
SELECT count(*) AS c FROM t_allnull
