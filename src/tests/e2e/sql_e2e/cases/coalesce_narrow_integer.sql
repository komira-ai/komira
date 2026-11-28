-- coalesce whose integer arms have DuckDB's common type TINYINT, a type this engine's CASE cannot produce, is refused by name.
SELECT id, coalesce(i8, 5) AS c FROM types ORDER BY id ASC NULLS LAST
