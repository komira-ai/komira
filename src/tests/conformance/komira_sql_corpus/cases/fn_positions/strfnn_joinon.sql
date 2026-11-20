-- order: rows
-- strpos(s, 'b') in a join condition
SELECT T.k AS k FROM T JOIN U ON T.k = U.j AND strpos(s, 'b') > 1
