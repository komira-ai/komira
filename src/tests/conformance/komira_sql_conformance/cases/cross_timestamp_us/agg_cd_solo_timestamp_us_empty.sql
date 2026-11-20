-- order: rows
-- agg cd solo over a TIMESTAMP column, empty rows
SELECT count(DISTINCT v) AS n FROM t_empty
