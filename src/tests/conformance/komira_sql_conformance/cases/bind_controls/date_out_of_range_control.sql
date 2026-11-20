-- order: rows
-- A control of a bind-error shape, with the faulty part repaired: the impossible day 30 replaced by 28
SELECT date_diff('day', DATE '2021-02-28', DATE '2021-03-01') AS z FROM T
