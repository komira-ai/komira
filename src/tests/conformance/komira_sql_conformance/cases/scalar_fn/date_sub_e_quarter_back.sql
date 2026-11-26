-- order: rows
SELECT k, date_sub('quarter', ts, TIMESTAMP '2021-01-03 12:00:00') FROM E
