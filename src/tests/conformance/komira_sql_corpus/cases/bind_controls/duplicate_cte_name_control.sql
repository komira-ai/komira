-- order: rows
-- Repaired form of a query that is wrong as first written: the second CTE binding of the same name removed
WITH c AS (SELECT k FROM T) SELECT k AS z FROM c
