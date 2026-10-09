# =============================================================================
# src/komira_http_core/codec/h1/status_text.mojo — static h1 response text
# =============================================================================
#
# The reason phrases and static error bodies `parser.mojo` serializes into its
# error and interim responses. No client-derived byte reaches either.
# =============================================================================


def _write_reason_phrase[W: Writer](mut writer: W, status: UInt16):
    """WRITE what `_reason_phrase` returns. ⚠ THIS WRITES; IT DOES NOT RETURN.

    The arms live here so no string constant is ever SELECTED and
    returned. A literal-returning ladder lowers to two parallel
    (pointer, length) constant arrays whose two call-site references
    an `--emit shared-lib` link binds INDEPENDENTLY, and a pair bound
    CROSSED takes the process down with it."""
    var s = Int(status)
    if s == 100:
        writer.write("Continue")
        return
    if s == 200:
        writer.write("OK")
        return
    if s == 400:
        writer.write("Bad Request")
        return
    if s == 413:
        writer.write("Payload Too Large")
        return
    if s == 414:
        writer.write("URI Too Long")
        return
    if s == 417:
        writer.write("Expectation Failed")
        return
    if s == 431:
        writer.write("Request Header Fields Too Large")
        return
    if s == 500:
        writer.write("Internal Server Error")
        return
    if s == 501:
        writer.write("Not Implemented")
        return
    if s == 505:
        writer.write("HTTP Version Not Supported")
        return
    writer.write("Error")
    return


def _write_static_error_body[W: Writer](mut writer: W, status: UInt16):
    """WRITE what `_static_error_body` returns. ⚠ THIS WRITES; IT DOES NOT RETURN.

    The arms live here so no string constant is ever SELECTED and
    returned. A literal-returning ladder lowers to two parallel
    (pointer, length) constant arrays whose two call-site references
    an `--emit shared-lib` link binds INDEPENDENTLY, and a pair bound
    CROSSED takes the process down with it."""
    var s = Int(status)
    if s == 400:
        writer.write("Bad Request\n")
        return
    if s == 413:
        writer.write("Payload Too Large\n")
        return
    if s == 414:
        writer.write("URI Too Long\n")
        return
    if s == 417:
        writer.write("Expectation Failed\n")
        return
    if s == 431:
        writer.write("Request Header Fields Too Large\n")
        return
    if s == 500:
        writer.write("Internal Server Error\n")
        return
    if s == 501:
        writer.write("Not Implemented\n")
        return
    if s == 505:
        writer.write("HTTP Version Not Supported\n")
        return
    writer.write("Error\n")
    return
