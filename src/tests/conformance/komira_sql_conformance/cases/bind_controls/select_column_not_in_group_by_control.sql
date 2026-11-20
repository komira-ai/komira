-- order: rows
-- Repaired form of a query that is wrong as first written: the ungrouped column s replaced by the grouping column g
SELECT g, count(*) AS c FROM T GROUP BY g
