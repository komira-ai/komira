"""A stub `komira_json` for the aws_client fixture: only what generated AWS code imports.

The generated AWS code does `from komira_json import JsonValue, parse_json_value`.
A library of the `tests` cell cannot depend on komira//src/komira_json (a
mojo_library of another cell carries another cell's MojoPkgTSet type), so
json_value.mojo is a small self-contained JSON value with exactly the API that
code calls, re-exported here under the real package's name.
"""

from .json_value import JsonValue, parse_json_value
