-- order: rows
SELECT k FROM T WHERE NOT (contains(note, 'q') OR tag = 'y9')
