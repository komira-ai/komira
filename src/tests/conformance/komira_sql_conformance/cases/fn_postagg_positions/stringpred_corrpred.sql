-- order: rows
-- starts_with(s, 'a') in a correlated exists predicate
SELECT T.k AS z FROM T WHERE EXISTS (SELECT 1 FROM U WHERE U.j = T.k AND starts_with(T.s, 'a'))
