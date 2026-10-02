"""A stub `komira_json` for the aws_client fixture.

The generated AWS code imports `JsonValue` and `parse_json_value` from
`komira_json`, the package komira//src/komira_json. A library of the `tests`
cell cannot depend on it (a mojo_library of another cell carries another
cell's MojoPkgTSet type), so this is a small self-contained stand-in with
the same package layout (value.mojo, parse.mojo, both re-exported here) and
exactly the API that code calls, under komira_json's names and signatures.
"""

from .value import (
    JSON_NULL,
    JSON_BOOL,
    JSON_NUMBER,
    JSON_STRING,
    JSON_ARRAY,
    JSON_OBJECT,
    JsonValue,
)
from .parse import parse_json_value
