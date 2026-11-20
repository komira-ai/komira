-- order: rows
-- A control of a bind-error shape, with the faulty part repaired: the aggregate moved out of WHERE into the SELECT list
SELECT median(v) AS z FROM T
