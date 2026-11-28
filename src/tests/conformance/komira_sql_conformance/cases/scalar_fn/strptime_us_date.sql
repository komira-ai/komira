-- order: rows
SELECT k, strptime('12/31/2028', '%m/%d/%Y') FROM T WHERE k < 2
