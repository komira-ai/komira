-- order: rows
-- multiply(k, 3) in a join condition
SELECT T.k AS k FROM T JOIN U ON T.k = U.j AND multiply(k, 3) > 9
