-- order: rows
-- join left unmatched over a VARCHAR column, allnull rows
SELECT a.k AS k, a.v AS v, b.v AS v_right FROM t_allnull a LEFT JOIN t_allnull b ON a.k = b.g
