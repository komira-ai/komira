-- order: rows
-- agg cd solo over a BOOLEAN column, allnull rows
SELECT count(DISTINCT v) AS n FROM t_allnull
