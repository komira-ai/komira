-- filter_bool.tsv: the rows whose b is true (a NULL b is not).
COPY (
SELECT id, k FROM read_json('rows.jsonl') WHERE b
) TO 'filter_bool.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
