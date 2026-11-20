-- order: rows
-- regexp_extract(s, '[a-z]+') in a correlated exists predicate
SELECT T.k AS z FROM T WHERE EXISTS (SELECT 1 FROM U WHERE U.j = T.k AND regexp_extract(T.s, '[a-z]+') = 'abc')
