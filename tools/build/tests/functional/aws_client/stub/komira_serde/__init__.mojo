"""A stub `komira_serde` for the aws_client fixture: only `json_value`.

The generated AWS code imports `JsonValue` and `parse_json_value` from
`komira_serde.json_value`. komira has no komira_serde, and a library of the
`tests` cell cannot depend on komira//src/komira_json (a mojo_library of
another cell carries another cell's MojoPkgTSet type), so json_value.mojo
is a small self-contained JSON value with exactly the API that code calls.
"""
