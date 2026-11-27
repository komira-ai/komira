-- TRY_CAST of text to BIGINT and INTEGER: NULL where the text is no number
-- or is past the type's range, the hexadecimal and binary spellings, an
-- exponent applied as DuckDB applies it, underscores, and NULL kept NULL.
SELECT id, txt, TRY_CAST(txt AS BIGINT) AS b, TRY_CAST(txt AS INTEGER) AS i FROM cast_text ORDER BY id ASC NULLS LAST
