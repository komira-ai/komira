-- order: rows
-- join inner on v over a TIMESTAMP column, full rows
SELECT a.k AS k, a.v AS v, b.k AS k_right FROM t_full a JOIN t_full b ON a.v = b.v
