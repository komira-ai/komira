-- order: rows
-- join right unmatched over a VARCHAR column, nulls rows
SELECT a.k AS k, a.v AS v, b.v AS v_right FROM t_nulls a RIGHT JOIN t_nulls b ON a.g = b.k
