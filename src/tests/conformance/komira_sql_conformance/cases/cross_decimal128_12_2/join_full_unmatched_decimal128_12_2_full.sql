-- order: rows
-- join full unmatched over a DECIMAL(12,2) column, full rows
SELECT a.k AS k, a.v AS v, b.v AS v_right FROM t_full a FULL JOIN t_full b ON a.k = b.g
