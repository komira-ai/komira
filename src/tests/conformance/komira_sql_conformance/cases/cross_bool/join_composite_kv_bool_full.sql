-- order: rows
-- join composite kv over a BOOLEAN column, full rows
SELECT a.k AS k, a.v AS v, b.v AS v_right FROM t_full a JOIN t_full b ON a.k = b.k AND a.v = b.v
