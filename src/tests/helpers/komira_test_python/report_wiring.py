"""A report test's `[report]`, and the table bench_table makes of it.

Arguments: the `[report]` of `:report_demo`, the `:report_demo_table`
output and its golden table, and the `:report_demo_pair_table` output and
its golden table. The run id file is staged beside this script. The report
must be exactly what report_demo.py printed, with `run_id` (the file's line)
and `target` (the test's label) put first; each table must be its golden one
with that run id. The pair table holds report_demo's lines before
report_demo_alpha's, as its `reports` give them, though `alpha` sorts first,
and no runs line, both reports being of one run id.
"""

import json
import os
import sys

from report_fixture import REPORT

report_path, table_path, golden_path, pair_path, pair_golden_path = sys.argv[1:]
here = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(here, "report_demo.run_id"), encoding="utf-8") as f:
    run_id = f.read().rstrip("\n")

with open(report_path, encoding="utf-8") as f:
    text = f.read()
want = {"run_id": run_id, "target": "komira//src/tests/helpers/komira_test_python:report_demo"}
want.update(REPORT)
assert list(json.loads(text).items()) == list(want.items()), "the report is\n" + text
assert text == json.dumps(want, indent=2) + "\n", "the report's bytes are\n" + text

for path, want_path in [(table_path, golden_path), (pair_path, pair_golden_path)]:
    with open(path, encoding="utf-8") as f:
        table = f.read()
    with open(want_path, encoding="utf-8") as f:
        golden = f.read().replace("@RUN_ID@", run_id)
    assert table == golden, "the table is\n" + table
print("ok report and tables, run id", run_id)
