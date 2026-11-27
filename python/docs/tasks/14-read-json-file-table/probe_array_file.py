# The form komira does not have yet: read a file that is one JSON array of
# records, as pandas read_json does by default (komira-ai/komira#2338).
# It must fail with the line of probe_array_file.error.txt.
import json
from pathlib import Path

import komira

Path("records.json").write_text(json.dumps([{"id": 1, "name": "ana"}, {"id": 2, "name": "bo"}]))

komira.read_json("records.json")
