-- order: rows
-- the unpivot's alias qualifies its columns in WHERE
SELECT name, score FROM W UNPIVOT (score FOR quarter IN (q1, q2, q3)) AS u WHERE u.score > 6
