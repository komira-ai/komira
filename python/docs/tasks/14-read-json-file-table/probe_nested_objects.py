# The form komira does not have yet: read records with a nested object as
# a struct column (komira-ai/komira#2338). It must fail with the line of
# probe_nested_objects.error.txt.
import json
from pathlib import Path

import komira

Path("orders.jsonl").write_text(json.dumps({"id": 1, "user": {"name": "ana"}}) + "\n")

komira.read_json("orders.jsonl", lines=True)
