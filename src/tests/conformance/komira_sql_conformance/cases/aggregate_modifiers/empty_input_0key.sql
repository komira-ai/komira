-- order: rows
SELECT count(*) AS c, count(v) AS cv, sum(v) AS s, min(v) AS mn, max(v) AS mx FROM T WHERE k < 0
