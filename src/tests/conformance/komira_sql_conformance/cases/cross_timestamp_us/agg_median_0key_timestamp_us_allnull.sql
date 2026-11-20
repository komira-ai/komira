-- order: rows
-- agg median 0key over a TIMESTAMP column, allnull rows
SELECT median(v) AS m FROM t_allnull
