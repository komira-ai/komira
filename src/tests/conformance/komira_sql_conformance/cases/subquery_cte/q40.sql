-- order: rows
-- a derived table read by a predicate subquery
SELECT k FROM T WHERE k IN (SELECT x FROM (SELECT j AS x FROM U) t)
