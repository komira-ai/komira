-- order: rows
-- join right unmatched over a BOOLEAN column, single rows
SELECT a.k AS k, a.v AS v, b.v AS v_right FROM t_single a RIGHT JOIN t_single b ON a.g = b.k
