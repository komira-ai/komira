-- order: rows
-- agg cd solo over a VARCHAR column, allnull rows
SELECT count(DISTINCT v) AS n FROM t_allnull
