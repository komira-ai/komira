-- order: rows
-- k on a group key in having
SELECT k AS z FROM T GROUP BY k HAVING k > 4
