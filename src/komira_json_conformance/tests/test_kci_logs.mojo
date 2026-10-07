# =============================================================================
# test_kci_logs.mojo -- kci's log-response scanner and body parsers, against JSONTestSuite
# =============================================================================
#
# Feeds every file of the pinned test_parsing corpus (318: 95 y_, 188 n_,
# 35 i_), as raw bytes, to the kci_logs testee (testees.mojo), prints every
# verdict, and gates them on allowlists/kci_logs.txt (gate.mojo); a corpus of any
# other size fails. An unlisted abort ends the process, so the test is red.
# Crash-only: json_skip_value checks nothing inside a value and the body
# parsers never raise by design, so its verdicts are printed and not gated.
# It catches a crash in the skipper, in json_scan_string on raw bytes, and in
# the three body parsers.
# =============================================================================

from komira_json_conformance import PARSER_KCI_LOGS, conformance_main


def main() raises:
    conformance_main(PARSER_KCI_LOGS)
    print("PASS komira_json_conformance kci_logs")
