-- order: rows
-- Repaired form of a query that is wrong as first written: the derived body narrowed to the one column the list names
SELECT z FROM (SELECT k FROM T) d (z)
