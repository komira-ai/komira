-- order: rows
-- Repaired form of a query that is wrong as first written: the second projected column removed from the subquery
SELECT k AS z FROM T WHERE k IN (SELECT j FROM U)
