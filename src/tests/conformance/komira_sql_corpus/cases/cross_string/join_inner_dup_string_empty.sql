-- order: rows
-- join inner dup over a VARCHAR column, empty rows
SELECT a.k AS k, a.v AS v, b.v AS v_right FROM t_empty a JOIN t_empty b ON a.k = b.g
