-- order: rows
-- join inner comma over a DECIMAL(12,2) column, empty rows
SELECT a.k AS k, a.v AS v, b.v AS v_right FROM t_empty a, t_empty b WHERE a.k = b.k
