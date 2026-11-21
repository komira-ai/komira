-- order_by.tsv: the rows by f descending (NULL last), then id.
COPY (
SELECT id, s FROM read_json('rows.jsonl') ORDER BY f DESC, id
) TO 'order_by.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
