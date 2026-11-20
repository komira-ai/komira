-- order: rows
-- agg cd with count over a UBIGINT column, full rows
SELECT count(*) AS c, count(DISTINCT v) AS n FROM t_full
