"""A report test: its standard output, one JSON object, is its `[report]`."""

import json

from report_fixture import REPORT

print(json.dumps(REPORT))
