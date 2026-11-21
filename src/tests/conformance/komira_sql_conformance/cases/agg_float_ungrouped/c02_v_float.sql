-- order: rows
-- SUM, AVG, MIN, MAX, COUNT and COUNT(*) of the FLOAT column over 4096 rows with NULLs
SELECT sum(f) AS s, avg(f) AS a, min(f) AS mn, max(f) AS mx, count(f) AS c, count(*) AS n FROM V
