-- order: rows
-- A control of a bind-error shape, with the faulty part repaired: the length literal -1 replaced by 1
SELECT substring(s, 1, 1) AS z FROM T
