-- order: rows
-- count(amount) leaves out the NULL amount and counts 0 for a missing pair
SELECT * FROM SALES PIVOT (count(amount) FOR product IN ('pen', 'ink'))
