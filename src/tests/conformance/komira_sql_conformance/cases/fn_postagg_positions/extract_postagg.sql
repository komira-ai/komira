-- order: rows
-- month(max(t)) around an aggregate in the select list
SELECT month(max(t)) AS z FROM T
