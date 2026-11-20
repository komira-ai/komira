-- order: rows
-- agg cd with count over a DECIMAL(12,2) column, empty rows
SELECT count(*) AS c, count(DISTINCT v) AS n FROM t_empty
