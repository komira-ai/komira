-- order: rows
-- the output column names DuckDB gives unaliased items
SELECT g, count(*) FROM T GROUP BY g
