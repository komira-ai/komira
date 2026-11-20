-- order: rows
-- agg cd with count over a BIGINT column, full rows
SELECT count(*) AS c, count(DISTINCT v) AS n FROM t_full
