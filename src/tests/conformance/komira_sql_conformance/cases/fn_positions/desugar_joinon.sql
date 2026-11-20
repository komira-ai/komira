-- order: rows
-- isnan(f) in a join condition
SELECT T.k AS k FROM T JOIN U ON T.k = U.j AND isnan(f)
