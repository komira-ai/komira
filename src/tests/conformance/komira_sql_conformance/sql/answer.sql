-- One corpus case: case.sql is run over the tables its corpus's tables.sql
-- built, and its answer written as answer.tsv (DuckDB's CSV writer, TAB
-- between cells, a header line). check.sql then holds it to the committed
-- answer.
--
-- The first line of case.sql names the row order the answer is written in:
--   -- order: query   the query's own ORDER BY decides it;
--   -- order: rows    the rows are a multiset: the runner writes them sorted
--                     by the text of each column in turn (its VARCHAR cast),
--                     NULLs first. It sorts on the text, not the values:
--                     this DuckDB writes a DOUBLE it sorted on from its sort
--                     key, which has no -0.0 (a -0.0 comes out 0.0).
SET VARIABLE case_sql = (SELECT content FROM read_text('case.sql'));
SELECT error('corpus case: case.sql must start with "-- order: query" or "-- order: rows" on a line of its own')
WHERE NOT (starts_with(getvariable('case_sql'), '-- order: query' || chr(10))
    OR starts_with(getvariable('case_sql'), '-- order: rows' || chr(10)));
SET VARIABLE run_sql = CASE
    WHEN starts_with(getvariable('case_sql'), '-- order: query' || chr(10)) THEN getvariable('case_sql')
    ELSE 'FROM (' || chr(10) || getvariable('case_sql') || chr(10) || ') ORDER BY COLUMNS(*)::VARCHAR ASC NULLS FIRST'
    END;
COPY (FROM query(getvariable('run_sql'))) TO 'answer.tsv' (FORMAT csv, DELIMITER '\t', HEADER true);
