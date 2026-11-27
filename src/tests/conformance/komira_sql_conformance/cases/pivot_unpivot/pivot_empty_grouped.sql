-- order: rows
-- no row and a group column: no row
SELECT * FROM EMPTY PIVOT (sum(amount) FOR product IN ('pen'))
