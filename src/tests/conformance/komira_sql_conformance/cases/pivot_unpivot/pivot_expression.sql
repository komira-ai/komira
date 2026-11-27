-- order: rows
-- an aggregate over an arithmetic names the columns inside it
SELECT * FROM SALES PIVOT (sum(amount * 2) FOR product IN ('pen', 'ink'))
