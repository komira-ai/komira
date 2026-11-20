-- order: rows
-- agg count 0key over a DECIMAL(12,2) column, empty rows
SELECT count(*) AS c FROM t_empty
