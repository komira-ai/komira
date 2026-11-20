-- order: rows
-- join inner comma over a BOOLEAN column, single rows
SELECT a.k AS k, a.v AS v, b.v AS v_right FROM t_single a, t_single b WHERE a.k = b.k
