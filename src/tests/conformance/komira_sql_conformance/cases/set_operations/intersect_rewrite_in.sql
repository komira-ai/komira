-- order: rows
SELECT DISTINCT k FROM ta WHERE k IN (SELECT k FROM tb)
