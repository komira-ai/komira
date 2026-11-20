-- order: rows
-- agg cd solo over a BOOLEAN column, empty rows
SELECT count(DISTINCT v) AS n FROM t_empty
