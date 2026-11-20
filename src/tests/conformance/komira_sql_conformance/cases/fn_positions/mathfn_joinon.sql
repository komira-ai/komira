-- order: rows
-- sqrt(g) in a join condition
SELECT T.k AS k FROM T JOIN U ON T.k = U.j AND sqrt(g) > 2.0
