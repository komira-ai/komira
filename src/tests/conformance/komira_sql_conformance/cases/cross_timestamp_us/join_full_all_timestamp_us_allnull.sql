-- order: rows
-- join full all over a TIMESTAMP column, allnull rows
SELECT a.k AS k, a.v AS v, b.v AS v_right FROM t_allnull a FULL JOIN t_allnull b ON a.k = b.k
