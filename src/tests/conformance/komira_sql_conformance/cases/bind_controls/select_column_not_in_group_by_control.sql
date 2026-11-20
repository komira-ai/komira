-- order: rows
-- A control of a bind-error shape, with the faulty part repaired: the ungrouped column s replaced by the grouping column g
SELECT g, count(*) AS c FROM T GROUP BY g
