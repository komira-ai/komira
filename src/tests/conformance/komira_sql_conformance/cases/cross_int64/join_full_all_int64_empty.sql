-- order: rows
-- join full all over a BIGINT column, empty rows
SELECT a.k AS k, a.v AS v, b.v AS v_right FROM t_empty a FULL JOIN t_empty b ON a.k = b.k
