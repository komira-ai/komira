-- order: rows
-- join right unmatched over a BOOLEAN column, empty rows
SELECT a.k AS k, a.v AS v, b.v AS v_right FROM t_empty a RIGHT JOIN t_empty b ON a.g = b.k
