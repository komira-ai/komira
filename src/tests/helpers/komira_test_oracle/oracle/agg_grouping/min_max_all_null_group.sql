-- order: none
-- Twin of the HAND case: MIN and MAX skip NULLs and are NULL over a group
-- of only NULLs (§2.1, §2.2); they keep the input's type (§8.7).
SELECT k, MIN(v) AS lo, MAX(v) AS hi
FROM groups
GROUP BY k
ORDER BY k ASC NULLS LAST
