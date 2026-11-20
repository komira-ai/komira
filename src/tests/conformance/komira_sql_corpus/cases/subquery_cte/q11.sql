-- order: rows
-- correlated scalar subquery in a projection (outer alias qualifier)
SELECT a.k AS k, (SELECT max(b.w) FROM U b WHERE b.j = a.k) AS m FROM T a
