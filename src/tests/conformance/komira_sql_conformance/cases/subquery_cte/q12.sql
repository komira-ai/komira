-- order: rows
-- correlated scalar subquery in a where predicate
SELECT a.k AS k FROM T a WHERE a.k + 100 < (SELECT max(b.w) FROM U b WHERE b.j = a.k)
