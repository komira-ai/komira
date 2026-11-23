-- count_star.tsv: count(*), which reads no column.
COPY (
SELECT count(*) AS c FROM read_json('rows.jsonl')
) TO 'count_star.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
