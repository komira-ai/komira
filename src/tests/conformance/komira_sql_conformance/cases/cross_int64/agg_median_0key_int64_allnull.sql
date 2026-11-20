-- order: rows
-- agg median 0key over a BIGINT column, allnull rows
SELECT median(v) AS m FROM t_allnull
