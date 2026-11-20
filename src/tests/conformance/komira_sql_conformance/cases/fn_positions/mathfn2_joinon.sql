-- order: rows
-- pow(n, 2) in a join condition
SELECT T.k AS k FROM T JOIN U ON T.k = U.j AND pow(n, 2) > 4.0
