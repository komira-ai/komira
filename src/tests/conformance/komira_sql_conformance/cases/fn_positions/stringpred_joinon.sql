-- order: rows
-- starts_with(s, 'a') in a join condition
SELECT T.k AS k FROM T JOIN U ON T.k = U.j AND starts_with(s, 'a')
