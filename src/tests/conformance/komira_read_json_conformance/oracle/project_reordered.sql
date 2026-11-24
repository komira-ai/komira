-- project_reordered.tsv: three columns in an order that is not the file's.
COPY (
SELECT s, n, id FROM read_json('rows.jsonl')
) TO 'project_reordered.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
