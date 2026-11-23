-- aggregate.tsv: ungrouped aggregates over integer and float columns with NULLs.
COPY (
SELECT count(*) AS c, count(n) AS cn, sum(n) AS sn, min(f) AS fmin, max(f) AS fmax FROM read_json('rows.jsonl')
) TO 'aggregate.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
