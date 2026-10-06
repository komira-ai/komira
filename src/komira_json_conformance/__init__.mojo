"""`komira_json_conformance`: every JSON parser komira ships, against
JSONTestSuite's test_parsing corpus (third_party/jsontestsuite).

Test-only; nothing depends on it. Modules:
  - suite.mojo   : the pinned corpus, read as raw bytes, with its exact counts;
  - testees.mojo : each parser behind one shape (return = accept, raise =
                   reject), and which parsers are crash-only;
  - gate.mojo    : the verdicts, the per-parser allowlist and the shrink-only
                   gate;
  - runner.mojo  : `conformance_main`, one parser's whole test, with the
                   child-process run of every ABORTS: file.
"""

from .gate import (
    ABORTS_MARK,
    AbortCheck,
    AllowEntry,
    FileResult,
    V_ACCEPT,
    V_BOUNDARY,
    V_MISREAD,
    V_REJECT,
    aborting_files,
    error_class,
    gate,
    parse_allowlist,
    verdict_name,
)
from .runner import (
    allowlist_path,
    check_parser,
    conformance_main,
    run_one,
    run_parser,
)
from .suite import (
    KIND_I,
    KIND_N,
    KIND_Y,
    SUITE_FILES,
    SUITE_I_FILES,
    SUITE_N_FILES,
    SUITE_Y_FILES,
    SuiteFile,
    check_suite_names,
    kind_of,
    load_suite,
    load_suite_from,
)
from .testees import (
    MISREAD,
    NOT_UTF8,
    PARSER_AVRO,
    PARSER_CONNECT,
    PARSER_JSON,
    PARSER_JSON_INDEX,
    PARSER_JSONL,
    PARSER_KCI_LOGS,
    PARSER_LOG_QUERY,
    PARSER_PROTO_CODEC,
    is_crash_only,
    parser_names,
    run_testee,
)
