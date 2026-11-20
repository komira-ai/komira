-- order: rows
-- join inner comma over a DECIMAL(12,2) column, nulls rows
SELECT a.k AS k, a.v AS v, b.v AS v_right FROM t_nulls a, t_nulls b WHERE a.k = b.k
