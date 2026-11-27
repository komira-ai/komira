-- order: rows
-- min of a BIGINT
SELECT * FROM SALES PIVOT (min(amount) FOR product IN ('pen', 'ink'))
