-- order: rows
SELECT CASE a WHEN 0 THEN 'zero' ELSE 'nz' END AS g, count(*) AS n FROM T GROUP BY CASE a WHEN 0 THEN 'zero' ELSE 'nz' END
