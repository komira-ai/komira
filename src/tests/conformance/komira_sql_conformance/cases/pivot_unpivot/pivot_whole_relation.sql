-- order: rows
-- no other column: one row over the whole relation
SELECT * FROM (SELECT product, amount FROM SALES) PIVOT (sum(amount) FOR product IN ('pen', 'ink'))
