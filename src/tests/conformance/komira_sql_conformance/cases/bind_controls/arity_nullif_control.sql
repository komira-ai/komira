-- order: rows
-- A control of a bind-error shape, with the faulty part repaired: the second (comparand) argument supplied
SELECT nullif(n, 2) AS z FROM T
