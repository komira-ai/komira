-- order: rows
SELECT T.k AS k, U.w AS w FROM T JOIN U ON T.k = U.j AND T.n > U.j
