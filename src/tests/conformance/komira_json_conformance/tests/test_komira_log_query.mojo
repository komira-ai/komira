# =============================================================================
# test_komira_log_query.mojo -- is_json_object_text, the log route embed check, against JSONTestSuite
# =============================================================================
#
# Feeds every file of the pinned test_parsing corpus (318: 95 y_, 188 n_,
# 35 i_), as raw bytes, to the komira_log_query testee (testees.mojo), prints every
# verdict, and gates them on allowlists/komira_log_query.txt (gate.mojo); a corpus of any
# other size fails. An unlisted abort ends the process, so the test is red.
# Its contract is exactly one object, so every y_ text whose top level is
# not an object is listed as rightly refused. An n_ object it accepted would
# let the route embed malformed JSON in its response: a NEW WRONG VERDICT.
# Its entry point takes a String: a file that is not UTF-8 is BOUNDARY.
# =============================================================================

from komira_json_conformance import PARSER_LOG_QUERY, conformance_main


def main() raises:
    conformance_main(PARSER_LOG_QUERY)
    print("PASS komira_json_conformance komira_log_query")
