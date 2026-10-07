# =============================================================================
# test_komira_json_index.mojo -- extract_column and the string unescaper, against JSONTestSuite
# =============================================================================
#
# Feeds every file of the pinned test_parsing corpus (318: 95 y_, 188 n_,
# 35 i_), as raw bytes, to the komira_json_index testee (testees.mojo), prints every
# verdict, and gates them on allowlists/komira_json_index.txt (gate.mojo); a corpus of any
# other size fails. An unlisted abort ends the process, so the test is red.
# Crash-only: the kernel's contract makes a malformed row NULL, never an
# error, so its verdicts are printed and not gated. It runs the extraction
# with `->` and `->>` on the text's first key, over the file's bytes verbatim,
# and the unescaper on the first string token. It catches a crash in the
# structural index, the key walk, the leaf extraction and the unescaper; it
# does not catch wrong output.
# =============================================================================

from komira_json_conformance import PARSER_JSON_INDEX, conformance_main


def main() raises:
    conformance_main(PARSER_JSON_INDEX)
    print("PASS komira_json_conformance komira_json_index")
