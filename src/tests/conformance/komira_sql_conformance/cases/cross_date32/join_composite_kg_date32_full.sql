-- order: rows
-- join composite kg over a DATE column, full rows
SELECT a.k AS k, a.v AS v, b.v AS v_right FROM t_full a JOIN t_full b ON a.k = b.k AND a.g = b.g
