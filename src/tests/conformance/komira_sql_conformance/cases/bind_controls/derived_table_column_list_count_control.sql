-- order: rows
-- A control of a bind-error shape, with the faulty part repaired: the derived body narrowed to the one column the list names
SELECT z FROM (SELECT k FROM T) d (z)
