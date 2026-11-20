-- order: rows
-- agg cd solo over a BIGINT column, full rows
SELECT count(DISTINCT v) AS n FROM t_full
