-- order: rows
-- agg sum where over a BIGINT column, empty rows
SELECT sum(v) AS s FROM t_empty WHERE k > 2
