-- order: rows
-- an UNPIVOT of a PIVOT gives back the pairs that had a value
SELECT * FROM SALES PIVOT (sum(amount) FOR product IN ('pen', 'ink')) UNPIVOT (v FOR p IN (pen, ink))
