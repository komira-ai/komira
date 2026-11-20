-- order: rows
-- agg median 0key over a DECIMAL(12,2) column, allnull rows
SELECT median(v) AS m FROM t_allnull
