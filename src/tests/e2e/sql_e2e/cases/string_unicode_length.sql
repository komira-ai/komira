-- length counts characters, not bytes, up to 4-byte characters.
SELECT id, length(str) AS n FROM types ORDER BY id ASC NULLS LAST
