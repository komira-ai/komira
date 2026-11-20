-- order: rows
-- Repaired form of a query that is wrong as first written: the derived-table alias renamed off the CTE's name
WITH c AS (SELECT k FROM T) SELECT z FROM (SELECT k AS z FROM T) d
