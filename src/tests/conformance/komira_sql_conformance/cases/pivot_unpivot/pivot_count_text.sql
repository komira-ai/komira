-- order: rows
-- count over a VARCHAR value
SELECT * FROM (SELECT region, product FROM SALES) PIVOT (count(product) FOR product IN ('pen', 'ink'))
