-- order: rows
-- s in a join condition
SELECT T.k AS k FROM T JOIN U ON T.k = U.j AND s = 'abc'
