-- count(*), count of a column with NULLs, count of an all-NULL column.
SELECT count(*) AS n, count(k) AS nk, count(all_null) AS na FROM nulls ORDER BY n ASC NULLS LAST
