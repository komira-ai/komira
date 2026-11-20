-- order: rows
-- A control of a bind-error shape, with the faulty part repaired: the two projected columns replaced by one scalar
SELECT k AS z FROM T WHERE v > (SELECT max(w) FROM U)
