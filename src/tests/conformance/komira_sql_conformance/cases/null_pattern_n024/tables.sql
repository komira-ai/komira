-- Table T with 24 rows: k (row number), v (k plus one), tag (never NULL) and note.
-- note repeats a pattern of an empty string, NULLs and short words, so a case can tell
-- an empty string from a NULL; the row count puts NULLs in a partial trailing group.
CREATE TABLE T (k INTEGER, v INTEGER, tag VARCHAR, note VARCHAR);
INSERT INTO T VALUES
    (0, 1, 'y1', ''),
    (1, 2, 'y3', NULL),
    (2, 3, 'y2', 'zzz'),
    (3, 4, 'y3', 'zzz'),
    (4, 5, 'y3', NULL),
    (5, 6, 'y1', 'bbb'),
    (6, 7, 'y2', NULL),
    (7, 8, 'y3', 'zab'),
    (8, 9, 'y1', ''),
    (9, 10, 'y3', NULL),
    (10, 11, 'y2', 'zzz'),
    (11, 12, 'y3', 'zzz'),
    (12, 13, 'y3', NULL),
    (13, 14, 'y1', 'bbb'),
    (14, 15, 'y2', NULL),
    (15, 16, 'y3', 'zab'),
    (16, 17, 'y1', ''),
    (17, 18, 'y3', NULL),
    (18, 19, 'y2', 'zzz'),
    (19, 20, 'y3', 'zzz'),
    (20, 21, 'y3', NULL),
    (21, 22, 'y1', 'bbb'),
    (22, 23, 'y2', NULL),
    (23, 24, 'y3', 'zab');
