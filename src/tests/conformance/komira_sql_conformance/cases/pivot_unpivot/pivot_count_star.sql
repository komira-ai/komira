-- order: rows
-- count(*) names no column, so amount is a group column; no row counts 0
SELECT * FROM SALES PIVOT (count(*) FOR product IN ('pen', 'ink'))
