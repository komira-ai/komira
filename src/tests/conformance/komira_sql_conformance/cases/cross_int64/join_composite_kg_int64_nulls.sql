-- order: rows
-- join composite kg over a BIGINT column, nulls rows
SELECT a.k AS k, a.v AS v, b.v AS v_right FROM t_nulls a JOIN t_nulls b ON a.k = b.k AND a.g = b.g
