-- order: rows
-- pow(n, 2) in a correlated exists predicate
SELECT T.k AS z FROM T WHERE EXISTS (SELECT 1 FROM U WHERE U.j = T.k AND pow(T.n, 2) > 4.0)
