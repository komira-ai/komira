"""`komira_connect_conformance`: komira_connect against the Connect
conformance suite (connectrpc/conformance, pinned in
third_party/connect-conformance).

The library is the test side of the run: reading the report the runner
prints (`parse_report`, `summary_problems`) and the reason rule of the
known-failing list (`parse_known_failing`). The server-under-test the runner
starts is the `conformance_server` binary (server/), built from
komira_connect alone: it cannot import this library, whose tests run it.
"""

from .known_failing import KnownFailing, parse_known_failing
from .summary import RunReport, RunSummary, parse_report, summary_problems
