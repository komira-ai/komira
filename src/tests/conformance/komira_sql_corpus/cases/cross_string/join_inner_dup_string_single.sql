-- order: rows
-- join inner dup over a VARCHAR column, single rows
SELECT a.k AS k, a.v AS v, b.v AS v_right FROM t_single a JOIN t_single b ON a.k = b.g
