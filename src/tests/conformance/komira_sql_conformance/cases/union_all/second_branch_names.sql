-- order: rows
-- the header takes the first branch's names
SELECT id AS first_id, s AS first_s FROM A UNION ALL SELECT id + 100 AS other_id, s AS other_s FROM B
