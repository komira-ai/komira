-- order: rows
-- isnan(sum(f)) around an aggregate in the select list
SELECT isnan(sum(f)) AS z FROM T
