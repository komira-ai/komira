-- order: rows
-- join right all over a TINYINT column, full rows
SELECT a.k AS k, a.v AS v, b.v AS v_right FROM t_full a RIGHT JOIN t_full b ON a.k = b.k
