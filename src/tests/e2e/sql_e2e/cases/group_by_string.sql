-- GROUP BY a string: '' and NULL are separate groups.
SELECT s, count(*) AS n FROM nulls GROUP BY s ORDER BY s ASC NULLS FIRST
