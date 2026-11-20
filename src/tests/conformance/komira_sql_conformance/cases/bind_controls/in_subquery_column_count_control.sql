-- order: rows
-- A control of a bind-error shape, with the faulty part repaired: the second projected column removed from the subquery
SELECT k AS z FROM T WHERE k IN (SELECT j FROM U)
