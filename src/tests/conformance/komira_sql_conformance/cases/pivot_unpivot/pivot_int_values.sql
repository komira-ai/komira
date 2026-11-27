-- order: rows
-- integer values name their columns by their digits
SELECT * FROM Q PIVOT (sum(v) FOR q IN (1, 2, 3))
