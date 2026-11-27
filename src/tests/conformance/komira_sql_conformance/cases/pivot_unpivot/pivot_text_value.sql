-- order: rows
-- max over a VARCHAR value
SELECT * FROM SALES PIVOT (max(region) FOR product IN ('pen', 'ink'))
