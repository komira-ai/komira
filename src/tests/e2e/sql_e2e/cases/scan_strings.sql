-- Strings: empty, Unicode up to 4 bytes, quotes, TAB, LF, CR, backslash, NULL.
SELECT id, str FROM types ORDER BY id ASC NULLS LAST
