-- order: rows
-- one column per listed value; a missing pair is NULL; south (pad only) keeps its row
SELECT * FROM SALES PIVOT (sum(amount) FOR product IN ('pen', 'ink'))
