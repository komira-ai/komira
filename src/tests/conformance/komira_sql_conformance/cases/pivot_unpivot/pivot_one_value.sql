-- order: rows
-- a value of the FOR column the list leaves out adds no column
SELECT * FROM SALES PIVOT (sum(amount) FOR product IN ('ink'))
