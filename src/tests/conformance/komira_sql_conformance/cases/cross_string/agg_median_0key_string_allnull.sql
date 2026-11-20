-- order: rows
-- agg median 0key over a VARCHAR column, allnull rows
SELECT median(v) AS m FROM t_allnull
