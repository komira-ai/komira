-- order: rows
-- join inner comma over a UTINYINT column, full rows
SELECT a.k AS k, a.v AS v, b.v AS v_right FROM t_full a, t_full b WHERE a.k = b.k
