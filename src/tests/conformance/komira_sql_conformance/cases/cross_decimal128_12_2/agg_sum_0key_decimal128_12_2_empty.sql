-- order: rows
-- agg sum 0key over a DECIMAL(12,2) column, empty rows
SELECT sum(v) AS s FROM t_empty
