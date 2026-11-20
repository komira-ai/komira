-- order: rows
-- the flat spelling of q20/q21 the aggregation with no derived table
SELECT g, count(*) AS c FROM T GROUP BY g
