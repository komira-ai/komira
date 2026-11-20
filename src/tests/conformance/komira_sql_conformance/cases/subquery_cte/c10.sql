-- order: rows
-- the flat spelling of q11/q12 the correlated body as an equi join
SELECT a.k AS k, b.w AS m FROM T a JOIN U b ON a.k = b.j
