# =============================================================================
# test_komira_proto_codec.mojo -- decode_json[Value], proto3-JSON, against JSONTestSuite
# =============================================================================
#
# Feeds every file of the pinned test_parsing corpus (318: 95 y_, 188 n_,
# 35 i_), as raw bytes, to the komira_proto_codec testee (testees.mojo), prints every
# verdict, and gates them on allowlists/komira_proto_codec.txt (gate.mojo); a corpus of any
# other size fails. An unlisted abort ends the process, so the test is red.
# Its entry point takes a String, so a file that is not UTF-8 is a BOUNDARY
# verdict, not a rejection of the decoder's. Its listed number cases are
# defects (DEFECT in the reason): a long decimal literal the standard
# library's float parser refuses, and an out-of-range literal decoded to an
# infinity the encoder then refuses to write.
# =============================================================================

from komira_json_conformance import PARSER_PROTO_CODEC, conformance_main


def main() raises:
    conformance_main(PARSER_PROTO_CODEC)
    print("PASS komira_json_conformance komira_proto_codec")
