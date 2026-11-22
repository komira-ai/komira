-- order: rows
-- INTEGER UNION ALL BIGINT widens to BIGINT
SELECT typeof(v) AS t, v FROM (SELECT i AS v FROM A UNION ALL SELECT bi FROM B) u
