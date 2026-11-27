-- order: rows
-- a listed value no row has is a column of NULLs
SELECT * FROM SALES PIVOT (sum(amount) FOR product IN ('pen', 'cap'))
