-- order: rows
-- agg sum where over a DECIMAL(12,2) column, allnull rows
SELECT sum(v) AS s FROM t_allnull WHERE k > 2
