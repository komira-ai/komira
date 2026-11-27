-- order: rows
-- an entry with no AS writes the table's spelling of the column (Q1)
SELECT * FROM M UNPIVOT (v FOR n IN (q1, q2))
