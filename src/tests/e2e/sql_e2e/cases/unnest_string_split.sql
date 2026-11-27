-- unnest of a list in the SELECT list: one row per element, the id repeated.
-- A NULL string splits to a NULL list, which gives no row; '' splits to the
-- one-element list [''].
SELECT id, unnest(string_split(s, 'a')) AS part FROM nulls ORDER BY id ASC NULLS LAST, part ASC NULLS LAST
