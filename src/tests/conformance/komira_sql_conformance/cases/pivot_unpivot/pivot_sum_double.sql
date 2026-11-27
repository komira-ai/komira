-- order: rows
-- sum of a DOUBLE
SELECT * FROM P PIVOT (sum(price) FOR product IN ('pen', 'ink', 'pad'))
