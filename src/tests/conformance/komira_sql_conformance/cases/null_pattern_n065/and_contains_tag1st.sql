-- order: rows
SELECT k FROM T WHERE NOT (tag = 'y3' AND contains(note, 'z'))
