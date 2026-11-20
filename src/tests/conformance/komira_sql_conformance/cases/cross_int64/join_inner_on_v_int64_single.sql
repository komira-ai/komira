-- order: rows
-- join inner on v over a BIGINT column, single rows
SELECT a.k AS k, a.v AS v, b.k AS k_right FROM t_single a JOIN t_single b ON a.v = b.v
