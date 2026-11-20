-- order: rows
-- join inner dup over a DECIMAL(12,2) column, allnull rows
SELECT a.k AS k, a.v AS v, b.v AS v_right FROM t_allnull a JOIN t_allnull b ON a.k = b.g
