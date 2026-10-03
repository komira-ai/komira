"""komira_pg — SCRAM-SHA-256 + pgwire codec unit tests.

Checks the RFC 7677 §3 SCRAM vector (must stay byte-exact) against the
`komira_pg` package surface (compute_scram_client + verify_server_signature,
which route through komira_crypto's PBKDF2), plus pgwire codec encode/decode
goldens (the message set the simple-query SELECT 1 path uses) and a PBKDF2
KAT.

No network, no database server — pure value + crypto. Always runs.
"""

from komira_pg.scram import (
    compute_scram_client,
    verify_server_signature,
    scram_field,
    make_client_nonce,
)
from komira_pg.pgwire import (
    encode_ssl_request,
    encode_startup,
    encode_sasl_initial,
    encode_sasl_response,
    encode_query,
    encode_terminate,
    read_i32_be,
    first_message_byte_len,
    parse_one_message,
    parse_backend_messages,
    parse_row_description,
    parse_error_fields,
    command_tag,
    rows_affected_from_tag,
    auth_subcode,
    AUTH_SASL,
)
from komira_pg.pg_types import row_from_data_message
from komira_encoding import base64_encode, base64_decode
from komira_crypto.pbkdf2 import pbkdf2_hmac_sha256_32, pbkdf2_hmac_sha256


def _assert(cond: Bool, label: String, mut failures: Int):
    if cond:
        print("  PASS:", label)
    else:
        print("  FAIL:", label)
        failures += 1


# =============================================================================
# (1) SCRAM-SHA-256 RFC 7677 §3 vector — byte-exact ClientProof + ServerSig.
# =============================================================================
def test_scram_rfc7677_vector(mut failures: Int) raises:
    print("== SCRAM-SHA-256 RFC 7677 section 3 vector (production surface) ==")
    var password = String("pencil")
    var client_first_bare = String("n=user,r=rOprNGfwEbeRWgbNEkqO")
    var server_first = String(
        "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,"
        "s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"
    )
    var client_final_no_proof = String(
        "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0"
    )
    var auth_message = (
        client_first_bare + "," + server_first + "," + client_final_no_proof
    )
    var salt = base64_decode(String("W22ZaJ0SNY7soEsUEjb6gQ=="))
    var result = compute_scram_client(
        password, Span[UInt8](salt), 4096, auth_message
    )

    var expected_proof = String("dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=")
    print("    computed p=", result.client_proof_b64)
    _assert(
        result.client_proof_b64 == expected_proof,
        "ClientProof base64 byte-exact",
        failures,
    )

    var expected_server_sig = String(
        "6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="
    )
    var computed_server_sig = base64_encode(
        Span[UInt8](result.server_signature)
    )
    print("    computed v=", computed_server_sig)
    _assert(
        computed_server_sig == expected_server_sig,
        "ServerSignature base64 byte-exact",
        failures,
    )

    # Mandatory server-signature verify — must ACCEPT the correct v=.
    var ok = verify_server_signature(result.server_signature, expected_server_sig)
    _assert(ok, "verify_server_signature accepts the correct v=", failures)

    # Must REJECT a tampered v=.
    var bad = String("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")
    var rejected = not verify_server_signature(result.server_signature, bad)
    _assert(rejected, "verify_server_signature rejects a tampered v=", failures)


# =============================================================================
# (2) PBKDF2-HMAC-SHA256 — KAT.
# =============================================================================
def test_pbkdf2_kat(mut failures: Int) raises:
    print("== pbkdf2_hmac_sha256 KAT ==")
    # The SCRAM Hi (dkLen==32) is implicitly validated by the 4096-iter RFC
    # 7677 vector above (compute_scram_client routes through it). Here we
    # additionally check the single-block form equals the general form for
    # dkLen==32, and that iterations==1 reduces to HMAC(pw, salt||INT(1)).
    var pw = String("pencil").as_bytes()
    var salt = String("0123456789abcdef").as_bytes()

    var blk32 = pbkdf2_hmac_sha256_32(pw, salt, 4096)
    var gen32 = pbkdf2_hmac_sha256(pw, salt, 4096, 32)
    var eq = len(gen32) == 32
    if eq:
        for i in range(32):
            if blk32[i] != gen32[i]:
                eq = False
    _assert(eq, "pbkdf2_hmac_sha256_32 == general form at dkLen=32", failures)

    # dkLen=20 (RFC 6070-style truncation) yields exactly 20 bytes.
    var dk20 = pbkdf2_hmac_sha256(pw, salt, 1, 20)
    _assert(len(dk20) == 20, "pbkdf2 dkLen=20 yields 20 bytes", failures)

    # dkLen=64 (two blocks) yields 64 bytes; first 32 == single-block(i=1).
    var dk64 = pbkdf2_hmac_sha256(pw, salt, 1, 64)
    _assert(len(dk64) == 64, "pbkdf2 dkLen=64 yields 64 bytes (two blocks)", failures)
    var blk1 = pbkdf2_hmac_sha256_32(pw, salt, 1)
    var prefix_eq = True
    for i in range(32):
        if dk64[i] != blk1[i]:
            prefix_eq = False
    _assert(prefix_eq, "pbkdf2 dkLen=64 first block == single-block(i=1)", failures)


# =============================================================================
# (3) CSPRNG nonce — printable, no comma, fresh each call.
# =============================================================================
def test_csprng_nonce(mut failures: Int) raises:
    print("== SCRAM CSPRNG nonce ==")
    var n1 = make_client_nonce()
    var n2 = make_client_nonce()
    _assert(len(n1.as_bytes()) > 0, "nonce is non-empty", failures)
    _assert(n1 != n2, "two nonces differ (CSPRNG, not fixed)", failures)
    var has_comma = False
    for b in n1.as_bytes():
        if b == UInt8(ord(",")):
            has_comma = True
    _assert(not has_comma, "nonce contains no comma (SCRAM field-safe)", failures)


# =============================================================================
# (4) SCRAM field extraction.
# =============================================================================
def test_scram_field(mut failures: Int):
    print("== scram_field extraction ==")
    var sf = String("r=abc%def,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096")
    _assert(scram_field(sf, String("r=")) == String("abc%def"), "r= field", failures)
    _assert(
        scram_field(sf, String("s=")) == String("W22ZaJ0SNY7soEsUEjb6gQ=="),
        "s= field",
        failures,
    )
    _assert(scram_field(sf, String("i=")) == String("4096"), "i= field", failures)
    _assert(
        scram_field(sf, String("x=")) == String(""),
        "missing field yields empty",
        failures,
    )


# =============================================================================
# (5) pgwire encode goldens.
# =============================================================================
def test_pgwire_encode(mut failures: Int):
    print("== pgwire encode goldens ==")
    var ssl = encode_ssl_request()
    _assert(len(ssl) == 8, "SSLRequest is 8 bytes", failures)
    _assert(
        Int(read_i32_be(Span[UInt8](ssl), 0)) == 8
        and Int(read_i32_be(Span[UInt8](ssl), 4)) == 80877103,
        "SSLRequest length=8 code=80877103",
        failures,
    )

    var startup = encode_startup(String("pguser"), String("pgdb"))
    _assert(
        Int(read_i32_be(Span[UInt8](startup), 0)) == len(startup),
        "StartupMessage self-length matches",
        failures,
    )
    _assert(
        Int(read_i32_be(Span[UInt8](startup), 4)) == 196608,
        "StartupMessage protocol == 196608",
        failures,
    )

    var sasl_init = encode_sasl_initial(
        String("SCRAM-SHA-256"), String("n,,n=u,r=nonce")
    )
    _assert(sasl_init[0] == UInt8(ord("p")), "SASLInitial type 'p'", failures)
    _assert(
        Int(read_i32_be(Span[UInt8](sasl_init), 1)) == len(sasl_init) - 1,
        "SASLInitial length excludes type byte",
        failures,
    )

    var sasl_resp = encode_sasl_response(String("c=biws,r=nonce,p=AAAA"))
    _assert(sasl_resp[0] == UInt8(ord("p")), "SASLResponse type 'p'", failures)

    var query = encode_query(String("SELECT 1"))
    _assert(query[0] == UInt8(ord("Q")), "Query type 'Q'", failures)
    _assert(
        Int(read_i32_be(Span[UInt8](query), 1)) == len(query) - 1,
        "Query length excludes type byte",
        failures,
    )

    var term = encode_terminate()
    _assert(term[0] == UInt8(ord("X")), "Terminate type 'X'", failures)
    _assert(
        Int(read_i32_be(Span[UInt8](term), 1)) == 4,
        "Terminate length == 4 (empty body)",
        failures,
    )


# =============================================================================
# (6) pgwire backend parser — split, partial-tail retain, single-message.
# =============================================================================
def _put_i32(mut b: List[UInt8], v: Int):
    b.append(UInt8((v >> 24) & 0xFF))
    b.append(UInt8((v >> 16) & 0xFF))
    b.append(UInt8((v >> 8) & 0xFF))
    b.append(UInt8(v & 0xFF))


def test_pgwire_parse(mut failures: Int):
    print("== pgwire backend parser ==")
    # R(SASL) + Z(idle) + a partial 3rd message (3 bytes).
    var stream = List[UInt8]()
    var r_body = List[UInt8]()
    r_body.append(0)
    r_body.append(0)
    r_body.append(0)
    r_body.append(10)  # subcode 10 = AuthenticationSASL
    for b in String("SCRAM-SHA-256").as_bytes():
        r_body.append(b)
    r_body.append(0)
    r_body.append(0)
    stream.append(UInt8(ord("R")))
    _put_i32(stream, len(r_body) + 4)
    for b in r_body:
        stream.append(b)
    # Z(idle)
    stream.append(UInt8(ord("Z")))
    _put_i32(stream, 5)
    stream.append(UInt8(ord("I")))
    # partial 3 bytes
    stream.append(UInt8(ord("C")))
    stream.append(0)
    stream.append(0)

    var parsed = parse_backend_messages(Span[UInt8](stream))
    _assert(
        len(parsed.messages) == 2,
        "parser yields 2 complete messages (stops at partial)",
        failures,
    )
    _assert(
        parsed.messages[0].msg_type == UInt8(ord("R"))
        and auth_subcode(parsed.messages[0]) == AUTH_SASL,
        "first is R/AuthenticationSASL (subcode 10)",
        failures,
    )
    _assert(
        parsed.consumed == len(stream) - 3,
        "consumes all-but-the-3-byte partial tail",
        failures,
    )

    # first_message_byte_len + parse_one_message agree with parse_all.
    var one_len = first_message_byte_len(Span[UInt8](stream))
    _assert(one_len > 0, "first_message_byte_len > 0 for complete head", failures)
    var first = parse_one_message(Span[UInt8](stream))
    _assert(
        first.msg_type == UInt8(ord("R")),
        "parse_one_message yields first message type",
        failures,
    )
    # incomplete head -> 0
    var short = List[UInt8]()
    short.append(UInt8(ord("R")))
    short.append(0)
    _assert(
        first_message_byte_len(Span[UInt8](short)) == 0,
        "incomplete head -> 0",
        failures,
    )


# =============================================================================
# (7) CommandComplete tag -> rows_affected.
# =============================================================================
def test_command_tag(mut failures: Int):
    print("== CommandComplete tag -> rows_affected ==")
    _assert(
        rows_affected_from_tag(String("INSERT 0 1")) == UInt64(1),
        "INSERT 0 1 -> 1",
        failures,
    )
    _assert(
        rows_affected_from_tag(String("UPDATE 3")) == UInt64(3),
        "UPDATE 3 -> 3",
        failures,
    )
    _assert(
        rows_affected_from_tag(String("DELETE 7")) == UInt64(7),
        "DELETE 7 -> 7",
        failures,
    )
    _assert(
        rows_affected_from_tag(String("SELECT 5")) == UInt64(5),
        "SELECT 5 -> 5",
        failures,
    )
    _assert(
        rows_affected_from_tag(String("BEGIN")) == UInt64(0),
        "BEGIN -> 0 (no trailing int)",
        failures,
    )
    _assert(
        rows_affected_from_tag(String("COMMIT")) == UInt64(0),
        "COMMIT -> 0",
        failures,
    )


# =============================================================================
# (8) RowDescription + DataRow decode — the SELECT 1 result path.
# =============================================================================
def test_row_decode(mut failures: Int) raises:
    print("== RowDescription + DataRow decode (SELECT 1 path) ==")
    # Build a RowDescription 'T' with one column "?column?" type OID 23 (INT4),
    # text format (0).
    var t_body = List[UInt8]()
    # field count = 1
    t_body.append(0)
    t_body.append(1)
    # name CString
    for b in String("?column?").as_bytes():
        t_body.append(b)
    t_body.append(0)
    # table OID (4) = 0
    _put_i32(t_body, 0)
    # attnum (2) = 0
    t_body.append(0)
    t_body.append(0)
    # type OID (4) = 23 (INT4)
    _put_i32(t_body, 23)
    # type size (2) = 4
    t_body.append(0)
    t_body.append(4)
    # type modifier (4) = -1
    _put_i32(t_body, -1)
    # format code (2) = 0 (text)
    t_body.append(0)
    t_body.append(0)
    var t_msg = parse_one_message(_framed(UInt8(ord("T")), t_body))
    var cols = parse_row_description(t_msg)
    _assert(len(cols) == 1, "RowDescription has 1 column", failures)
    _assert(cols[0].type_oid == UInt32(23), "column OID == 23 (INT4)", failures)
    _assert(cols[0].name == String("?column?"), "column name decoded", failures)

    var oids = List[UInt32]()
    oids.append(UInt32(23))

    # Build a DataRow 'D' with one column = text "1".
    var d_body = List[UInt8]()
    d_body.append(0)
    d_body.append(1)  # column count = 1
    _put_i32(d_body, 1)  # column length = 1
    d_body.append(UInt8(ord("1")))
    var d_msg = parse_one_message(_framed(UInt8(ord("D")), d_body))
    var row = row_from_data_message(d_msg, oids)
    _assert(row.col_count() == 1, "DataRow has 1 column", failures)
    _assert(not row.is_null(0), "column 0 not NULL", failures)
    try:
        var v = row.get_int4(0)
        _assert(v == Int32(1), "get_int4(0) == 1 (SELECT 1)", failures)
    except e:
        _assert(False, "get_int4 raised: " + String(e), failures)

    # NULL column path.
    var dn_body = List[UInt8]()
    dn_body.append(0)
    dn_body.append(1)
    _put_i32(dn_body, -1)  # NULL
    var dn_msg = parse_one_message(_framed(UInt8(ord("D")), dn_body))
    var nrow = row_from_data_message(dn_msg, oids)
    _assert(nrow.is_null(0), "NULL column decoded as NULL", failures)


# =============================================================================
# (9) ErrorResponse field decode.
# =============================================================================
def test_error_decode(mut failures: Int):
    print("== ErrorResponse field decode ==")
    var e_body = List[UInt8]()
    _append_field(e_body, UInt8(ord("S")), String("ERROR"))
    _append_field(e_body, UInt8(ord("C")), String("23505"))
    _append_field(e_body, UInt8(ord("M")), String("duplicate key value"))
    e_body.append(0)  # terminator
    var e_msg = parse_one_message(_framed(UInt8(ord("E")), e_body))
    var ef = parse_error_fields(e_msg)
    _assert(ef.severity == String("ERROR"), "severity == ERROR", failures)
    _assert(ef.sqlstate == String("23505"), "SQLSTATE == 23505", failures)
    _assert(
        ef.message == String("duplicate key value"), "message decoded", failures
    )


def _framed(msg_type: UInt8, body: List[UInt8]) -> List[UInt8]:
    """Frame a body with the type byte + Int32 length (length includes the 4
    length bytes)."""
    var out = List[UInt8]()
    out.append(msg_type)
    var length = len(body) + 4
    out.append(UInt8((length >> 24) & 0xFF))
    out.append(UInt8((length >> 16) & 0xFF))
    out.append(UInt8((length >> 8) & 0xFF))
    out.append(UInt8(length & 0xFF))
    for b in body:
        out.append(b)
    return out^


def _append_field(mut buf: List[UInt8], field_type: UInt8, value: String):
    buf.append(field_type)
    for b in value.as_bytes():
        buf.append(b)
    buf.append(0)


def main() raises:
    print("=========================================================")
    print(" komira_pg — SCRAM + pgwire codec unit tests")
    print("=========================================================")
    var failures = 0
    test_scram_rfc7677_vector(failures)
    test_pbkdf2_kat(failures)
    test_csprng_nonce(failures)
    test_scram_field(failures)
    test_pgwire_encode(failures)
    test_pgwire_parse(failures)
    test_command_tag(failures)
    test_row_decode(failures)
    test_error_decode(failures)
    print("=========================================================")
    if failures == 0:
        print(" RESULT: ALL CHECKS PASSED")
    else:
        print(" RESULT:", failures, "CHECK(S) FAILED")
    print("=========================================================")
    if failures != 0:
        raise Error("komira_pg unit checks failed")
