-- order: rows
-- max of a DOUBLE, a NULL price and an unlisted product
SELECT * FROM P PIVOT (max(price) FOR product IN ('pen', 'ink'))
