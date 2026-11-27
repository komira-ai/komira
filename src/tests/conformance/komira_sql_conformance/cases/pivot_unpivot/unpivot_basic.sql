-- order: rows
-- the other columns, then the name column, then the value; NULL values are left out
SELECT * FROM W UNPIVOT (score FOR quarter IN (q1, q2, q3))
