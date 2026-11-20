-- order: rows
-- A control of a bind-error shape, with the faulty part repaired: the group index -1 replaced by 1
SELECT regexp_extract(s, '(a)(b)', 1) AS z FROM T
