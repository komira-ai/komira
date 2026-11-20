-- order: rows
-- a scalar subquery over a string column
SELECT k FROM T WHERE s = (SELECT max(s) FROM T)
