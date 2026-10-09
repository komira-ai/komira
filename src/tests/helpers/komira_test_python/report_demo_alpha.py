"""A second report test, for a table of two reports: its standard output is its `[report]`."""

import json

from report_fixture import REPORT_ALPHA

print(json.dumps(REPORT_ALPHA))
