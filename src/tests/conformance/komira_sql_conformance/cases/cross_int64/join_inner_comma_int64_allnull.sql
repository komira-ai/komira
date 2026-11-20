-- order: rows
-- join inner comma over a BIGINT column, allnull rows
SELECT a.k AS k, a.v AS v, b.v AS v_right FROM t_allnull a, t_allnull b WHERE a.k = b.k
