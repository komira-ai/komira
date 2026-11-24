-- year, month and day of a DATE.
SELECT id, year(date32) AS y, month(date32) AS m, day(date32) AS d FROM types ORDER BY id ASC NULLS LAST
