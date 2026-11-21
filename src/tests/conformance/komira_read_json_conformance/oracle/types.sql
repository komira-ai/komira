-- types.tsv: the name and the type DuckDB's read_json gives each column of rows.jsonl.
COPY (
SELECT column_name, column_type FROM (DESCRIBE SELECT * FROM read_json('rows.jsonl'))
) TO 'types.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
