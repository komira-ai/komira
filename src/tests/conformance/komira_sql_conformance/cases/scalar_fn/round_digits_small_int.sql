-- order: rows
SELECT k, round(CAST(m AS SMALLINT), -1) AS rs, round(CAST(m AS TINYINT), -1) AS rt, trunc(CAST(m AS TINYINT), -1) AS tt FROM T WHERE k <> 8
