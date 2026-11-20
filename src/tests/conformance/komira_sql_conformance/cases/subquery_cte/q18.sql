-- order: rows
-- a derived table with a column-list alias `t(a)`
SELECT a FROM (SELECT k FROM T) t(a)
