-- order: rows
-- agg cd solo over a VARCHAR column, empty rows
SELECT count(DISTINCT v) AS n FROM t_empty
