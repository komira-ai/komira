-- order: rows
-- join composite kv over a TIMESTAMP column, nulls rows
SELECT a.k AS k, a.v AS v, b.v AS v_right FROM t_nulls a JOIN t_nulls b ON a.k = b.k AND a.v = b.v
