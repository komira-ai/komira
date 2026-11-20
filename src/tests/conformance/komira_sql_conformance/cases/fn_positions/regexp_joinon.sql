-- order: rows
-- regexp_extract(s, '[a-z]+') in a join condition
SELECT T.k AS k FROM T JOIN U ON T.k = U.j AND regexp_extract(s, '[a-z]+') = 'abc'
