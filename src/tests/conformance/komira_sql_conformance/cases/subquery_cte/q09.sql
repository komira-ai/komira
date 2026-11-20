-- order: rows
-- a scalar subquery whose body is itself a derived table
SELECT k FROM T WHERE k > (SELECT min(x) FROM (SELECT j AS x FROM U) t)
