-- order: rows
-- agg cd solo over a DECIMAL(12,2) column, allnull rows
SELECT count(DISTINCT v) AS n FROM t_allnull
