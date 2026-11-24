-- scan_all.tsv: every row and every column of rows.jsonl, in the order read_json gives the keys.
COPY (
SELECT * FROM read_json('rows.jsonl')
) TO 'scan_all.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
