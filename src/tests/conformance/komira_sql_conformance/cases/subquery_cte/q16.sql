-- order: rows
-- a derived table `from (select ...) t`
SELECT k FROM (SELECT k FROM T) t
