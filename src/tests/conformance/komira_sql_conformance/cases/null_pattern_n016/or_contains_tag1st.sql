-- order: rows
SELECT k FROM T WHERE NOT (tag = 'y9' OR contains(note, 'q'))
