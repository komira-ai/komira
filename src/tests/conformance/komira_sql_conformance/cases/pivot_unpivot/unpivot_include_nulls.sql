-- order: rows
-- INCLUDE NULLS keeps the NULL values
SELECT * FROM W UNPIVOT INCLUDE NULLS (score FOR quarter IN (q1, q2, q3))
