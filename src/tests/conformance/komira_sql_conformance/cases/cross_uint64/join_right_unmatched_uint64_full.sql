-- order: rows
-- join right unmatched over a UBIGINT column, full rows
SELECT a.k AS k, a.v AS v, b.v AS v_right FROM t_full a RIGHT JOIN t_full b ON a.g = b.k
