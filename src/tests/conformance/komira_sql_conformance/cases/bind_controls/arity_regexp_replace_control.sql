-- order: rows
-- A control of a bind-error shape, with the faulty part repaired: the pattern and replacement arguments supplied
SELECT regexp_replace(s, 'b', 'X') AS z FROM T
