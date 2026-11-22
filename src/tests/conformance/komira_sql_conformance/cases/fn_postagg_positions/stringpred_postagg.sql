-- order: rows
-- starts_with(max(s), 'a') around an aggregate in the select list
SELECT starts_with(max(s), 'a') AS z FROM T
