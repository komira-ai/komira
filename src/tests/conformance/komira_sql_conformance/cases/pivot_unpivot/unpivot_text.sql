-- order: rows
-- VARCHAR columns unpivot; an empty string is kept, a NULL left out
SELECT * FROM W UNPIVOT (txt FOR k IN (name, note))
