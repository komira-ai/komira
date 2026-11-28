-- The tree `write_tree` made, staged as a directory input (`input_dirs`) at
-- `t/`: its files are the ones it listed, and read back with Hive
-- partitioning they hold the rows of data.csv.
SELECT CASE WHEN string_agg(file, ' ' ORDER BY file)
        <> 't/no_amount=false/data_0.csv t/no_amount=true/data_0.csv'
    THEN error('the tree holds ' || string_agg(file, ' ' ORDER BY file)) END
FROM glob('t/**');

SELECT CASE WHEN string_agg(file, ' ' ORDER BY file)
        <> 'tree/no_amount=false/data_0.csv tree/no_amount=true/data_0.csv'
    THEN error('files.tsv lists ' || string_agg(file, ' ' ORDER BY file)) END
FROM read_csv('files.tsv', delim = '\t', header = true);

COPY (SELECT id, name, no_amount FROM read_csv('t/**/*.csv', hive_partitioning = true) ORDER BY id)
TO 'tree_rows.tsv' (FORMAT csv, DELIMITER '\t', HEADER true);

SELECT CASE WHEN string_agg(id || ':' || name || ':' || no_amount, ' ' ORDER BY id)
        <> '1:alice:false 2:bob:true 3:carol:false'
    THEN error('the tree reads back as ' || string_agg(id || ':' || name || ':' || no_amount, ' ' ORDER BY id)) END
FROM read_csv('tree_rows.tsv', delim = '\t', header = true);
