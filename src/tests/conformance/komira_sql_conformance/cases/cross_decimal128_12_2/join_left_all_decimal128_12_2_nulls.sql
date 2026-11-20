-- order: rows
-- join left all over a DECIMAL(12,2) column, nulls rows
SELECT a.k AS k, a.v AS v, b.v AS v_right FROM t_nulls a LEFT JOIN t_nulls b ON a.k = b.k
