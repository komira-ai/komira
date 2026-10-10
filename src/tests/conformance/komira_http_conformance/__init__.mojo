"""`komira_http_conformance`: komira_http_server against an external HTTP/2
conformance suite (h2spec), test-only.

  * `report`    - an h2spec run's per-case results, from its JUnit report,
                  and its stdout summary counts;
  * `allowlist` - the reviewed list of cases the server still fails, and the
                  shrink-only gate over a run;
  * `child`     - run a child process to completion under a deadline;
  * `duet`      - step an HttpServer on one thread while a client leg runs
                  on another;
  * `tls`       - the server's TLS configuration and a verifying client
                  connector, over komira_http_core's test certificates.
"""

from .allowlist import AllowEntry, gate, parse_allowlist
from .child import ChildOutcome, run_child
from .duet import ClientLeg, serve_while
from .report import (
    CASE_FAILED,
    CASE_PASSED,
    CASE_SKIPPED,
    CaseResult,
    SummaryCounts,
    count,
    parse_junit,
    parse_summary,
)
from .tls import ROOT_CA_PATH, client_tls_connector, server_tls_config
