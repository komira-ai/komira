-- order: rows
-- the pivot's alias qualifies its columns in WHERE
SELECT * FROM SALES PIVOT (sum(amount) FOR product IN ('pen', 'ink')) AS p WHERE p.pen > 5
