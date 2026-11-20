-- order: rows
-- agg cd solo over a FLOAT column, full rows
SELECT count(DISTINCT v) AS n FROM t_full
