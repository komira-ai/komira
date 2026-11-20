-- order: rows
-- A control of a bind-error shape, with the faulty part repaired: the end-date argument supplied
SELECT date_diff('day', DATE '2021-01-01', DATE '2021-01-31') AS z FROM T
