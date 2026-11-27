# The form komira does not have yet: the || operator. It must fail with the
# line of probe_pipe_operator.error.txt.
from pathlib import Path

import komira

Path("people.csv").write_text("id,first,last\n1,Ana,Diaz\n")

with komira.Session() as s:
    s.register_csv("people", "people.csv")
    print(s.sql("SELECT first || ' ' || last AS name FROM people").to_arrow().to_pylist())
