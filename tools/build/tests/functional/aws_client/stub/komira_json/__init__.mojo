"""A stub `komira_json` for the aws_client fixture.

The generated AWS code imports `JsonValue` and `parse_json_value` from
`komira_json`, the package komira//src/komira_json. A library of the `tests`
cell cannot depend on it (a mojo_library of another cell carries another
cell's MojoPkgTSet type), so this is a small self-contained stand-in with
the same package layout (value.mojo, parse.mojo, both re-exported here).

It carries the subset of komira_json's API that the generated code calls,
with the same names and signatures. Behaviour is simplified: the parser
refuses `\\u` escapes, accepts number text loosely (it keeps whatever run
of digits, `-` and `.` it finds), and reports errors without a line and
column. A generated client is not built against the real komira_json in
this cell.
"""

from .value import (
    JSON_NULL,
    JSON_BOOL,
    JSON_NUMBER,
    JSON_STRING,
    JSON_ARRAY,
    JSON_OBJECT,
    JsonValue,
    parse_int64_text,
    parse_uint64_text,
)
from .parse import JSON_DEFAULT_MAX_DEPTH, JSON_MAX_DEPTH, parse_json_value
