-- order: rows
-- join inner on v over a BOOLEAN column, empty rows
SELECT a.k AS k, a.v AS v, b.k AS k_right FROM t_empty a JOIN t_empty b ON a.v = b.v
