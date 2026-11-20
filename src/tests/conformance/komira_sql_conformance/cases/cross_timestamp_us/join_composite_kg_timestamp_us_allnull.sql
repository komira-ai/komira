-- order: rows
-- join composite kg over a TIMESTAMP column, allnull rows
SELECT a.k AS k, a.v AS v, b.v AS v_right FROM t_allnull a JOIN t_allnull b ON a.k = b.k AND a.g = b.g
