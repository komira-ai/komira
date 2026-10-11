-- The settings sql_oracle fixes, read back: a change to threads in the rule
-- fails this target. The farm's workers run in UTC, so a dropped
-- `SET TimeZone` does not; the sql_oracle self-test pins it in the
-- invocation (buck2 aquery).
SELECT CASE
    WHEN current_setting('threads') <> 1 THEN error('threads is ' || current_setting('threads') || ', not 1')
    WHEN current_setting('TimeZone') <> 'UTC' THEN error('TimeZone is ' || current_setting('TimeZone') || ', not UTC')
END;

-- The input, read from the working directory by its path there. The
-- timestamps carry offsets other than UTC, so the TSV shows the session's
-- time zone at work.
CREATE TABLE t AS
SELECT * FROM read_csv('data.csv', header = true,
    columns = {'id': 'INTEGER', 'name': 'VARCHAR', 'amount': 'DOUBLE', 'ts': 'TIMESTAMPTZ'});

COPY (SELECT * FROM t ORDER BY id) TO 'rows.parquet' (FORMAT parquet);
COPY (SELECT * FROM t ORDER BY id) TO 'rows.csv' (FORMAT csv, HEADER true);
-- An expected result as the oracle datasets write them.
COPY (SELECT name, amount, ts FROM t ORDER BY id) TO 'expected.tsv' (FORMAT csv, DELIMITER '\t', HEADER true);
