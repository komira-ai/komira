-- order: rows
-- join left all over a BIGINT column, empty rows
SELECT a.k AS k, a.v AS v, b.v AS v_right FROM t_empty a LEFT JOIN t_empty b ON a.k = b.k
