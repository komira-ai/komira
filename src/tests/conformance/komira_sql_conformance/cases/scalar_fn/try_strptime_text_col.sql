-- order: rows
SELECT k, try_strptime(s || ' 2028', 'abc %Y') FROM T
