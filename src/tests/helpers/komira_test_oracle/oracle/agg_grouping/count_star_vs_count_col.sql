-- order: none
-- not null: n, nv
-- Twin of the HAND case: COUNT(*) counts rows, COUNT(v) non-NULL v (§2.1);
-- NULL keys form one group (§2.4); COUNT is INT64, never NULL (§8.6).
SELECT k, COUNT(*) AS n, COUNT(v) AS nv
FROM groups
GROUP BY k
ORDER BY k ASC NULLS LAST
