-- order: rows
-- SUM, AVG, MIN, MAX, COUNT and COUNT(*) of the DOUBLE column over 4096 rows with NULLs
SELECT sum(d) AS s, avg(d) AS a, min(d) AS mn, max(d) AS mx, count(d) AS c, count(*) AS n FROM V
