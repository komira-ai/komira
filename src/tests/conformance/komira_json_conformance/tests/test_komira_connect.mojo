# =============================================================================
# test_komira_connect.mojo -- parse_connect_error_json, against JSONTestSuite
# =============================================================================
#
# Feeds every file of the pinned test_parsing corpus (318: 95 y_, 188 n_,
# 35 i_), as raw bytes, to the komira_connect testee (testees.mojo), prints every
# verdict, and gates them on allowlists/komira_connect.txt (gate.mojo); a corpus of any
# other size fails. An unlisted abort ends the process, so the test is red.
# Crash-only: a tolerant scan for two keys, not a JSON parser, so its
# verdicts are printed and not gated. It catches a crash on hostile bytes.
# =============================================================================

from komira_json_conformance import PARSER_CONNECT, conformance_main


def main() raises:
    conformance_main(PARSER_CONNECT)
    print("PASS komira_json_conformance komira_connect")
