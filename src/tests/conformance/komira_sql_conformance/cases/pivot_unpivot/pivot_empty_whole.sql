-- order: rows
-- no row and no group column: one row of NULLs
SELECT * FROM (SELECT product, amount FROM EMPTY) PIVOT (sum(amount) FOR product IN ('pen'))
