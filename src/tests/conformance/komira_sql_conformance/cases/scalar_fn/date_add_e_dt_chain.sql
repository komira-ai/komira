-- order: rows
SELECT k, date_add(date_add(dt, INTERVAL '1' MONTH), INTERVAL '1' DAY) AS r FROM E
