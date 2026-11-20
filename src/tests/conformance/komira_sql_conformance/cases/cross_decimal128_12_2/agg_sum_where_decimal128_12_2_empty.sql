-- order: rows
-- agg sum where over a DECIMAL(12,2) column, empty rows
SELECT sum(v) AS s FROM t_empty WHERE k > 2
