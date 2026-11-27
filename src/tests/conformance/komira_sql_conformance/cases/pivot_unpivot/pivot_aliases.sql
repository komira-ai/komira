-- order: rows
-- an IN alias names the column; an aggregate alias is appended as _total
SELECT * FROM SALES PIVOT (sum(amount) AS total FOR product IN ('pen' AS p, 'ink'))
