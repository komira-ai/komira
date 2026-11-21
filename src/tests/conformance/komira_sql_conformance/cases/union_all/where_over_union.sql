-- order: rows
-- a filter over a derived union
SELECT id, v FROM (SELECT id, bi AS v FROM A UNION ALL SELECT id, i FROM B) u WHERE v > 0
