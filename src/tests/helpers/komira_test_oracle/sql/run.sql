-- One oracle case: case.sql is held to the discipline (discipline.sql) and
-- then run, its answer written as expected.tsv, a header line and one line
-- per row, TAB between cells; NULL is an empty unquoted cell, the empty
-- string "" (DuckDB's CSV writer, README.md says how each type is spelt).
SET VARIABLE case_sql = (SELECT content FROM read_text('case.sql'));
SELECT error('oracle discipline: case.sql ' || string_agg(offence, '; ' ORDER BY offence))
FROM oracle_offences(getvariable('case_sql')) HAVING count(*) > 0;
COPY (FROM query(getvariable('case_sql'))) TO 'expected.tsv' (FORMAT csv, DELIMITER '\t', HEADER true);
