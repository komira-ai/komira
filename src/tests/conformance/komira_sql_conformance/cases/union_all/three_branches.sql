-- order: rows
-- three branches fold to the widest type, SMALLINT then BIGINT
SELECT typeof(v) AS t, v FROM (SELECT ti AS v FROM A UNION ALL SELECT si FROM B UNION ALL SELECT bi FROM A) u
