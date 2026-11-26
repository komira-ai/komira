-- order: rows
SELECT k, date_sub('day', ts, TIMESTAMP '1969-12-31 12:00:00') FROM E
