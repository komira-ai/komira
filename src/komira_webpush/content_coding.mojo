# =============================================================================
# komira_webpush/content_coding.mojo: the "aes128gcm" content coding (RFC 8188)
# =============================================================================
#
# A body is a header followed by records:
#
#   salt (16) | rs (4, big-endian) | idlen (1) | keyid (idlen) | records
#
# Each record is AEAD_AES_128_GCM over `data || delimiter || zero padding`,
# rs bytes long except the last, which may be shorter. The delimiter is 0x02
# in the last record and 0x01 in every other record. The additional data is
# empty.
#
# Keys (section 2.2 and 2.3), with HKDF over SHA-256:
#
#   PRK   = HKDF-Extract(salt, IKM)
#   CEK   = HKDF-Expand(PRK, "Content-Encoding: aes128gcm" || 0x00, 16)
#   NONCE = HKDF-Expand(PRK, "Content-Encoding: nonce" || 0x00, 12) XOR SEQ
#
# where SEQ is the record's index as a 96-bit big-endian integer.
#
# `aes128gcm_encrypt` writes one record with no padding (the shape Web Push
# requires, RFC 8291 section 4). `aes128gcm_decrypt` reads any number of
# records and refuses, each with its own message: a body shorter than its
# header, an rs below 18, a body with no record, a record shorter than 17
# bytes, a record that fails authentication, a record with no non-zero
# byte, and a delimiter that does not match the record's position.
#
# The PRK, the CEK, the base nonce and each record's nonce are overwritten
# with zeros after their last use and before any raise that follows their
# creation (CEK and base nonce by `Aes128GcmKeys.__deinit__`). One AES-GCM
# context per call is built from the CEK, which it borrows. No test observes
# the wipe.
# =============================================================================

from komira_crypto import AesGcm128, Hkdf, Sha256, zeroize_inline_array


comptime SALT_SIZE: Int = 16
"""Bytes of the header's salt."""
comptime HEADER_FIXED_SIZE: Int = 21
"""salt (16) + rs (4) + idlen (1), the header without its keyid."""
comptime TAG_SIZE: Int = 16
"""Bytes of the AES-GCM tag on each record."""
comptime MIN_RECORD_SIZE: Int = 18
"""The smallest rs RFC 8188 section 2.1 allows."""
comptime DELIMITER_LAST: UInt8 = 0x02
"""Padding delimiter of the last record."""
comptime DELIMITER_NOT_LAST: UInt8 = 0x01
"""Padding delimiter of every record but the last."""


struct Aes128GcmKeys(Movable, Deinitable):
    """The content-encryption key and the base nonce of RFC 8188 section 2.2
    and 2.3 (before the XOR with a record's sequence number). Both are wiped
    when the value is destroyed."""

    var cek: Array[UInt8, 16]
    var nonce: Array[UInt8, 12]

    def __init__(out self, var cek: Array[UInt8, 16], var nonce: Array[UInt8, 12]):
        self.cek = cek^
        self.nonce = nonce^

    def __deinit__(deinit self):
        zeroize_inline_array(self.cek)
        zeroize_inline_array(self.nonce)


def _ascii_with_nul(s: StaticString) -> List[UInt8]:
    var bs = s.as_bytes()
    var out = List[UInt8](capacity=len(bs) + 1)
    for i in range(len(bs)):
        out.append(bs[i])
    out.append(UInt8(0x00))
    return out^


def aes128gcm_keys(ikm: Span[UInt8, _], salt: Span[UInt8, _]) raises -> Aes128GcmKeys:
    """Derives CEK and the base nonce from IKM and the header's salt.

    Raises:
        "aes128gcm: salt must be 16 bytes, got <n>"
    """
    if len(salt) != SALT_SIZE:
        raise Error("aes128gcm: salt must be 16 bytes, got " + String(len(salt)))
    var prk = Hkdf[Sha256].extract(salt, ikm)
    # The keys are expanded into an Aes128GcmKeys, whose destructor wipes
    # them if an expand raises.
    var keys = Aes128GcmKeys(
        Array[UInt8, 16](fill=UInt8(0)), Array[UInt8, 12](fill=UInt8(0))
    )
    var cek_info = _ascii_with_nul("Content-Encoding: aes128gcm")
    var nonce_info = _ascii_with_nul("Content-Encoding: nonce")
    try:
        Hkdf[Sha256].expand(
            Span[UInt8](prk), Span[UInt8](cek_info), Span[UInt8](keys.cek)
        )
        Hkdf[Sha256].expand(
            Span[UInt8](prk), Span[UInt8](nonce_info), Span[UInt8](keys.nonce)
        )
    finally:
        zeroize_inline_array(prk)
    return keys^


def _record_nonce(base: Array[UInt8, 12], seq: Int) -> Array[UInt8, 12]:
    var out = base.copy()
    var s = UInt64(seq)
    for i in range(8):
        out[11 - i] = out[11 - i] ^ UInt8((s >> UInt64(8 * i)) & UInt64(0xFF))
    return out^


def aes128gcm_encrypt(
    ikm: Span[UInt8, _],
    salt: Span[UInt8, _],
    keyid: Span[UInt8, _],
    rs: Int,
    plaintext: Span[UInt8, _],
) raises -> List[UInt8]:
    """Encodes `plaintext` as one aes128gcm record behind its header.

    Args:
        ikm: The input keying material.
        salt: 16 bytes; never reuse one with the same IKM.
        keyid: The header's key identifier, at most 255 bytes.
        rs: The record size written in the header, in [18, 2^32 - 1].
        plaintext: At most rs - 17 bytes (one record).

    Returns:
        header || ciphertext || tag.

    Raises:
        "aes128gcm: salt must be 16 bytes, got <n>"
        "aes128gcm: keyid must be at most 255 bytes, got <n>"
        "aes128gcm: rs must be at least 18, got <rs>"
        "aes128gcm: rs must fit 32 bits, got <rs>"
        "aes128gcm: plaintext of <n> bytes does not fit one record of
         rs <rs> (at most <rs - 17>)"
    """
    if len(keyid) > 255:
        raise Error(
            "aes128gcm: keyid must be at most 255 bytes, got "
            + String(len(keyid))
        )
    if rs < MIN_RECORD_SIZE:
        raise Error("aes128gcm: rs must be at least 18, got " + String(rs))
    if rs > 0xFFFFFFFF:
        raise Error("aes128gcm: rs must fit 32 bits, got " + String(rs))
    var room = rs - TAG_SIZE - 1
    if len(plaintext) > room:
        raise Error(
            "aes128gcm: plaintext of "
            + String(len(plaintext))
            + " bytes does not fit one record of rs "
            + String(rs)
            + " (at most "
            + String(room)
            + ")"
        )
    var keys = aes128gcm_keys(ikm, salt)

    var out = List[UInt8](
        capacity=HEADER_FIXED_SIZE + len(keyid) + len(plaintext) + 1 + TAG_SIZE
    )
    for i in range(SALT_SIZE):
        out.append(salt[i])
    out.append(UInt8((rs >> 24) & 0xFF))
    out.append(UInt8((rs >> 16) & 0xFF))
    out.append(UInt8((rs >> 8) & 0xFF))
    out.append(UInt8(rs & 0xFF))
    out.append(UInt8(len(keyid)))
    for i in range(len(keyid)):
        out.append(keyid[i])

    var record = List[UInt8](capacity=len(plaintext) + 1 + TAG_SIZE)
    for i in range(len(plaintext)):
        record.append(plaintext[i])
    record.append(DELIMITER_LAST)
    for _ in range(TAG_SIZE):
        record.append(UInt8(0))
    var cipher = AesGcm128(keys.cek)
    var empty = List[UInt8]()
    var nonce = _record_nonce(keys.nonce, 0)
    # seal_in_place raises for a buffer under 16 bytes or a failing
    # EVP_AEAD_CTX_seal. Here the record is at least 17 bytes and below
    # 2^32 (rs fits 32 bits), under AES-GCM's 2^36 - 32 input limit, and
    # the nonce is 12 bytes, so it does not raise.
    try:
        cipher.seal_in_place(nonce, Span[UInt8](empty), Span[UInt8](record))
    finally:
        zeroize_inline_array(nonce)
    for i in range(len(record)):
        out.append(record[i])
    return out^


@fieldwise_init
struct Aes128GcmHeader(Copyable, Movable):
    """The parsed header of an aes128gcm body."""

    var salt: Array[UInt8, 16]
    var rs: Int
    var keyid: List[UInt8]
    var records_offset: Int
    """Where the first record starts in the body."""


def aes128gcm_parse_header(body: Span[UInt8, _]) raises -> Aes128GcmHeader:
    """Reads the header of an aes128gcm body.

    Raises:
        "aes128gcm: body of <n> bytes is shorter than the 21-byte header"
        "aes128gcm: rs must be at least 18, got <rs>"
        "aes128gcm: body of <n> bytes is shorter than its header with a
         <idlen>-byte keyid"
    """
    if len(body) < HEADER_FIXED_SIZE:
        raise Error(
            "aes128gcm: body of "
            + String(len(body))
            + " bytes is shorter than the 21-byte header"
        )
    var salt = Array[UInt8, 16](fill=UInt8(0))
    for i in range(SALT_SIZE):
        salt[i] = body[i]
    var rs = (
        (Int(body[16]) << 24)
        | (Int(body[17]) << 16)
        | (Int(body[18]) << 8)
        | Int(body[19])
    )
    if rs < MIN_RECORD_SIZE:
        raise Error("aes128gcm: rs must be at least 18, got " + String(rs))
    var idlen = Int(body[20])
    if len(body) < HEADER_FIXED_SIZE + idlen:
        raise Error(
            "aes128gcm: body of "
            + String(len(body))
            + " bytes is shorter than its header with a "
            + String(idlen)
            + "-byte keyid"
        )
    var keyid = List[UInt8](capacity=idlen)
    for i in range(idlen):
        keyid.append(body[HEADER_FIXED_SIZE + i])
    return Aes128GcmHeader(salt^, rs, keyid^, HEADER_FIXED_SIZE + idlen)


def aes128gcm_decrypt(ikm: Span[UInt8, _], body: Span[UInt8, _]) raises -> List[UInt8]:
    """Decodes an aes128gcm body of one or more records.

    Returns:
        The concatenated record data, padding removed.

    Raises:
        Every refusal of `aes128gcm_parse_header`, and:
        "aes128gcm: body holds no record"
        "aes128gcm: record <i> is <n> bytes, shorter than 17"
        "aes128gcm: record <i> failed authentication"
        "aes128gcm: record <i> has no padding delimiter"
        "aes128gcm: last record <i> has delimiter <d>, want 2"
        "aes128gcm: record <i> has delimiter <d>, want 1 (not the last record)"
    """
    var header = aes128gcm_parse_header(body)
    var start = header.records_offset
    var total = len(body)
    if start == total:
        raise Error("aes128gcm: body holds no record")
    var keys = aes128gcm_keys(ikm, Span[UInt8](header.salt))
    var cipher = AesGcm128(keys.cek)
    var out = List[UInt8]()
    var empty = List[UInt8]()
    var seq = 0
    while start < total:
        var end = start + header.rs
        if end > total:
            end = total
        var n = end - start
        if n < TAG_SIZE + 1:
            raise Error(
                "aes128gcm: record "
                + String(seq)
                + " is "
                + String(n)
                + " bytes, shorter than 17"
            )
        var is_last = end == total
        var record = List[UInt8](capacity=n)
        for i in range(start, end):
            record.append(body[i])
        var nonce = _record_nonce(keys.nonce, seq)
        try:
            cipher.open_in_place(
                nonce, Span[UInt8](empty), Span[UInt8](record)
            )
            zeroize_inline_array(nonce)
        except:
            zeroize_inline_array(nonce)
            raise Error(
                "aes128gcm: record " + String(seq) + " failed authentication"
            )
        var data_end = n - TAG_SIZE
        var d = data_end - 1
        while d >= 0 and record[d] == UInt8(0):
            d -= 1
        if d < 0:
            raise Error(
                "aes128gcm: record " + String(seq) + " has no padding delimiter"
            )
        var delimiter = record[d]
        if is_last and delimiter != DELIMITER_LAST:
            raise Error(
                "aes128gcm: last record "
                + String(seq)
                + " has delimiter "
                + String(Int(delimiter))
                + ", want 2"
            )
        if not is_last and delimiter != DELIMITER_NOT_LAST:
            raise Error(
                "aes128gcm: record "
                + String(seq)
                + " has delimiter "
                + String(Int(delimiter))
                + ", want 1 (not the last record)"
            )
        for i in range(d):
            out.append(record[i])
        start = end
        seq += 1
    return out^
