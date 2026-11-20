-- order: rows
-- a derived table read through its alias qualifier
SELECT t.k AS k FROM (SELECT k FROM T) t
