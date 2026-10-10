# =============================================================================
# test_komira_avro.mojo -- the Avro reader's schema JSON, through an OCF header, against JSONTestSuite
# =============================================================================
#
# Feeds every file of the pinned test_parsing corpus (318: 95 y_, 188 n_,
# 35 i_), as raw bytes, to the komira_avro testee (testees.mojo), prints every
# verdict, and gates them on allowlists/komira_avro.txt (gate.mojo); a corpus of any
# other size fails. An unlisted abort ends the process, so the test is red.
# The file's bytes go in as the avro.schema value of an OCF header, the
# reader's path for untrusted schema text. It refuses ill-formed UTF-8 and a
# lone surrogate escape (those i_ files are recorded as REJECTS:) and no file
# aborts it. Its number and string scans are lenient (those n_ files are
# listed as ACCEPTED:).
# =============================================================================

from komira_json_conformance import PARSER_AVRO, conformance_main


def main() raises:
    conformance_main(PARSER_AVRO)
    print("PASS komira_json_conformance komira_avro")
