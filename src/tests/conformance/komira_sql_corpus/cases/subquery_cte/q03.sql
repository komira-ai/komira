-- order: rows
-- scalar subquery whose value is arithmetic-combined in the predicate
SELECT k FROM T WHERE k > (SELECT min(j) FROM U) + 1
