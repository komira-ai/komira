-- filter_compare.tsv: the rows whose n is above 2 (a NULL or missing n is not).
COPY (
SELECT id, f FROM read_json('rows.jsonl') WHERE n > 2
) TO 'filter_compare.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
