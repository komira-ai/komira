-- order: rows
-- join left unmatched over a BIGINT column, full rows
SELECT a.k AS k, a.v AS v, b.v AS v_right FROM t_full a LEFT JOIN t_full b ON a.k = b.g
