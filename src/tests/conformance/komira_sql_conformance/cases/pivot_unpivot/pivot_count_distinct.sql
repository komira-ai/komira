-- order: rows
-- count(DISTINCT amount) per pair
SELECT * FROM SALES PIVOT (count(DISTINCT amount) FOR product IN ('pen', 'ink'))
