-- order: rows
-- join full unmatched over a BIGINT column, single rows
SELECT a.k AS k, a.v AS v, b.v AS v_right FROM t_single a FULL JOIN t_single b ON a.k = b.g
