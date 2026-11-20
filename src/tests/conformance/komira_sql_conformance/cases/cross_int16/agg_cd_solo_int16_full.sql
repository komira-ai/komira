-- order: rows
-- agg cd solo over a SMALLINT column, full rows
SELECT count(DISTINCT v) AS n FROM t_full
