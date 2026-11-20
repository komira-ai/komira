-- order: rows
-- scalar subquery in a where predicate
SELECT k FROM T WHERE k > (SELECT min(j) FROM U)
