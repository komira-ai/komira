# =============================================================================
# test_komira_jsonl.mojo -- the JSONL reader (infer, then materialize), against JSONTestSuite
# =============================================================================
#
# Feeds every file of the pinned test_parsing corpus (318: 95 y_, 188 n_,
# 35 i_), as raw bytes, to the komira_jsonl testee (testees.mojo), prints every
# verdict, and gates them on allowlists/komira_jsonl.txt (gate.mojo); a corpus of any
# other size fails. An unlisted abort ends the process, so the test is red.
# A text read right is one object coming back as exactly one row; a text
# whose top level is anything else, returned without an error, is MISREAD
# (testees.mojo). The reader refuses a line that is not one JSON object
# (the y_ files whose top level is anything else are listed as REJECTED:, the
# format's contract) and a repeated key; the n_ files it accepts are listed.
# =============================================================================

from komira_json_conformance import PARSER_JSONL, conformance_main


def main() raises:
    conformance_main(PARSER_JSONL)
    print("PASS komira_json_conformance komira_jsonl")
