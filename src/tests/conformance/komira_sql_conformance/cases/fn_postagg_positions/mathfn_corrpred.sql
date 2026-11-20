-- order: rows
-- sqrt(g) in a correlated exists predicate
SELECT T.k AS z FROM T WHERE EXISTS (SELECT 1 FROM U WHERE U.j = T.k AND sqrt(T.g) > 2.0)
