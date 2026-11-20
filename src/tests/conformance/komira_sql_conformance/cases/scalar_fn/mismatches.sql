-- order: rows
SELECT k, mismatches(s, u) FROM T WHERE k IN (1,2,3,5,6,7,8,9,12)
