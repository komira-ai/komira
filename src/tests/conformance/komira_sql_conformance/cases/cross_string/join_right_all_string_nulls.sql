-- order: rows
-- join right all over a VARCHAR column, nulls rows
SELECT a.k AS k, a.v AS v, b.v AS v_right FROM t_nulls a RIGHT JOIN t_nulls b ON a.k = b.k
