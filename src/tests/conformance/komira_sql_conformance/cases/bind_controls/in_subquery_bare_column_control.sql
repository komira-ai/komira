-- order: rows
-- A control of a bind-error shape, with the faulty part repaired: the computed projection j + 1 replaced by the bare column j
SELECT k AS z FROM T WHERE k IN (SELECT j FROM U)
