# =============================================================================
# test_komira_json.mojo -- parse_json_bytes, the strict RFC 8259 parser, against JSONTestSuite
# =============================================================================
#
# Feeds every file of the pinned test_parsing corpus (318: 95 y_, 188 n_,
# 35 i_), as raw bytes, to the komira_json testee (testees.mojo), prints every
# verdict, and gates them on allowlists/komira_json.txt (gate.mojo); a corpus of any
# other size fails. An unlisted abort ends the process, so the test is red.
# Its allowlist lists no y_ or n_ file: it must accept every y_ file and
# reject every n_ file. It records the verdict on each i_ file (10 ACCEPTS:
# for numbers past a double's range, kept as text; 25 REJECTS: for lone
# surrogate escapes, ill-formed UTF-8 (UTF-16 text included), a BOM and
# nesting past its depth limit). A grammar regression on an n_ file (a trailing comma, a leading
# zero, an unescaped control character) is a NEW WRONG VERDICT; letting a lone
# surrogate escape or ill-formed UTF-8 through is a CHANGED i_ VERDICT, since
# the suite files those cases under i_.
# =============================================================================

from komira_json_conformance import PARSER_JSON, conformance_main


def main() raises:
    conformance_main(PARSER_JSON)
    print("PASS komira_json_conformance komira_json")
