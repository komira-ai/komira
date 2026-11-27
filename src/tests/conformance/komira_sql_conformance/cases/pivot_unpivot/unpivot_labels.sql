-- order: rows
-- AS gives the name column's value, an identifier or a string
SELECT * FROM W UNPIVOT (score FOR quarter IN (q1 AS 'first', q2 AS second))
