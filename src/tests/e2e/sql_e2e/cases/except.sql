-- EXCEPT: distinct left keys not on the right.
SELECT k FROM join_left EXCEPT SELECT k FROM join_right ORDER BY k ASC NULLS FIRST
