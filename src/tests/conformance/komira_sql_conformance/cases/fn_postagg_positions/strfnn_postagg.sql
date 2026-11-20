-- order: rows
-- strpos(max(s), 'b') around an aggregate in the select list
SELECT strpos(max(s), 'b') AS z FROM T
