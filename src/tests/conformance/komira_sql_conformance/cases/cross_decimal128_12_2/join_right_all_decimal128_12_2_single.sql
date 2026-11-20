-- order: rows
-- join right all over a DECIMAL(12,2) column, single rows
SELECT a.k AS k, a.v AS v, b.v AS v_right FROM t_single a RIGHT JOIN t_single b ON a.k = b.k
