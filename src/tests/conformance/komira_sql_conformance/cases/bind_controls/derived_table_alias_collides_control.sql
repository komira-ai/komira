-- order: rows
-- A control of a bind-error shape, with the faulty part repaired: the derived-table alias renamed off the CTE's name
WITH c AS (SELECT k FROM T) SELECT z FROM (SELECT k AS z FROM T) d
