-- order: rows
-- avg is DOUBLE
SELECT * FROM SALES PIVOT (avg(amount) FOR product IN ('pen', 'ink'))
