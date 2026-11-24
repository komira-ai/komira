-- filter_unprojected.tsv: a filter on a column the result does not hold.
COPY (
SELECT s FROM read_json('rows.jsonl') WHERE f < 1
) TO 'filter_unprojected.tsv' (FORMAT csv, DELIMITER E'\t', HEADER true);
