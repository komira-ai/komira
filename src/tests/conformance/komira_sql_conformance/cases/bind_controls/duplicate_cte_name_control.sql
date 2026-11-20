-- order: rows
-- A control of a bind-error shape, with the faulty part repaired: the second CTE binding of the same name removed
WITH c AS (SELECT k FROM T) SELECT k AS z FROM c
