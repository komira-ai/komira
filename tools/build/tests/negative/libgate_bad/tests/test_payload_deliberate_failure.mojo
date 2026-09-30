from libgate_bad import payload_width


def main() raises:
    print("test_payload_deliberate_failure: about to fail deliberately")
    if payload_width() == 7:
        raise Error(
            "libgate_bad: DELIBERATE FAILURE. This is the negative fixture for"
            " the mojo_library test gate."
        )
