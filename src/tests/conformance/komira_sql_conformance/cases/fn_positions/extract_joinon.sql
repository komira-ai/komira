-- order: rows
-- month(t) in a join condition
SELECT T.k AS k FROM T JOIN U ON T.k = U.j AND month(t) > 5
