-- order: rows
SELECT k FROM T WHERE NOT (contains(note, 'z') AND tag = 'y3')
