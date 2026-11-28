-- order: rows
SELECT k, strptime('Sun, 31 Dec 2028 1:02:03.5 pm', '%a, %d %b %Y %I:%M:%S.%f %p') FROM T WHERE k = 0
