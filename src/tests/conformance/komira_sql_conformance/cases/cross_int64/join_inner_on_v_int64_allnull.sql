-- order: rows
-- join inner on v over a BIGINT column, allnull rows
SELECT a.k AS k, a.v AS v, b.k AS k_right FROM t_allnull a JOIN t_allnull b ON a.v = b.v
