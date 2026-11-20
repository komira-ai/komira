-- order: rows
-- join full all over a VARCHAR column, single rows
SELECT a.k AS k, a.v AS v, b.v AS v_right FROM t_single a FULL JOIN t_single b ON a.k = b.k
