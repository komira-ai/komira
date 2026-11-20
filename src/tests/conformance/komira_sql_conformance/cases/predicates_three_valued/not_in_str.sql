-- order: rows
SELECT k, (s NOT IN ('abc', 'zzz')) AS z FROM T
