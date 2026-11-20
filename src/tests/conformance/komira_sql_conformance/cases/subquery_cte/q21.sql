-- order: rows
-- an aggregate over a derived table
SELECT sum(x) AS s FROM (SELECT v AS x FROM T) t
