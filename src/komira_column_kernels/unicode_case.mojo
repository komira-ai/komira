"""`upper(s)` / `lower(s)` over UTF-8 — the byte-level driver for the SIMPLE
case mapping in `unicode_case_table.mojo`.

★ WHY AN ASCII-ONLY LOOP IS INVISIBLY WRONG. A byte loop
(`if 'a' <= b <= 'z': b - 32`) that passes every byte >= 0x80 through
VERBATIM is a SILENT WRONG ANSWER, not a refusal: `upper('Ünïcodé')` comes
back `'ÜNïCODé'` — the ASCII letters folded, the accented ones not, no
error, and a result that is still valid UTF-8 and still the right length,
so nothing downstream can notice. Coverage of a NAME is not coverage of
its DOMAIN.

⛔ THE MAPPING IS PER-CODEPOINT, SO THE KERNEL MUST DECODE. A byte-wise rule
cannot express any of it: `é` is C3 A9 and `É` is C3 89, so the transformation
lives in the SECOND byte and depends on the first. This is the exact opposite of
`trim`/`hex`/`url_encode` in `compiler_eval_column.mojo`, which are byte-defined
in DuckDB too and therefore need no decoder.

★ SIMPLE (1:1) MAPPING IS ENOUGH FOR PARITY, AND THAT IS MEASURED, NOT ASSUMED.
The table's generator asked DuckDB v1.5.3 for `upper(chr(cp))` and
`lower(chr(cp))` over all 1,112,064 legal codepoints: every answer is exactly ONE
codepoint. So DuckDB is doing utf8proc's SIMPLE mapping, `upper('ß')` is `'ẞ'`
(U+1E9E) and not `'SS'`, and no expansion buffer is needed here.
⚠ Do NOT "upgrade" this to full case folding. It would answer `'STRASSE'` where
the oracle says `'STRAẞE'` — a new divergence, introduced as an improvement.

⚠ OUTPUT LENGTH IS NOT INPUT LENGTH. `upper('ß')` grows 2 bytes to 3 and
`upper('ı')` shrinks 2 bytes to 1, so the `List[UInt8]` this returns is sized by
what was written, never by `len(s)`.

⚠ MALFORMED INPUT IS COPIED THROUGH, BYTE FOR BYTE, NEVER RAISED ON AND NEVER
REPLACED. A truncated or invalid sequence is emitted verbatim, so a
data-quality problem in one row cannot fail the query or silently rewrite bytes
the caller did not ask about. It also makes the kernel byte-preserving on any
input it does not understand.
"""

from komira_column_kernels.unicode_case_table import simple_lower_cp, simple_upper_cp


def _utf8_seq_len(b0: UInt8) -> Int:
    """Bytes in the sequence led by `b0`, or 0 if `b0` cannot lead one.

    0 is returned for continuation bytes (0x80..0xBF), for the overlong
    2-byte leads 0xC0/0xC1, and for 0xF5..0xFF — every case where the caller
    must copy the byte through rather than decode it.
    """
    if b0 < 0x80:
        return 1
    if b0 < 0xC2:
        return 0
    if b0 < 0xE0:
        return 2
    if b0 < 0xF0:
        return 3
    if b0 < 0xF5:
        return 4
    return 0


def _encode_utf8_into(cp: Int, mut out: List[UInt8]):
    """Append the UTF-8 encoding of one scalar value.

    ⛔ NEVER `chr(Int(...))` AND NEVER `String`. That is the standing
    corruption trap (written up on `_hex_string_bytes` and friends in
    `compiler_eval_column.mojo`): routing bytes through a `String` re-encodes
    anything >= 0x80 a second time and doubles it. Appending the encoded bytes
    directly is the whole reason this driver returns `List[UInt8]`.
    """
    if cp < 0x80:
        out.append(UInt8(cp))
    elif cp < 0x800:
        out.append(UInt8(0xC0 | (cp >> 6)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
    elif cp < 0x10000:
        out.append(UInt8(0xE0 | (cp >> 12)))
        out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
    else:
        out.append(UInt8(0xF0 | (cp >> 18)))
        out.append(UInt8(0x80 | ((cp >> 12) & 0x3F)))
        out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (cp & 0x3F)))


def _case_fold_bytes[to_upper: Bool](s: String) -> List[UInt8]:
    """The shared driver. `upper` and `lower` differ ONLY in which table
    function they call, so they share a body rather than a copy-paste pair that
    can drift, where both halves would have to be found to fix either.

    ⚠ `to_upper` IS A COMPILE-TIME PARAMETER, NOT AN ARGUMENT, AND THE
    DIFFERENCE IS THE INNER LOOP. As a runtime `Bool` it would be tested once
    per BYTE of every string column this evaluates; as a parameter the two
    instantiations are branch-free and identical in shape to two separate
    functions. Sharing the body costs nothing at run time."""
    var b = s.as_bytes()
    var n = len(b)
    # Capacity is a hint, not a bound: see the length note in the header.
    var out = List[UInt8](capacity=n)
    var i = 0
    while i < n:
        var b0 = b[i]
        # ASCII, the overwhelming majority of real bytes, without decoding.
        if b0 < 0x80:
            var c = Int(b0)
            if to_upper:
                if b0 >= 0x61 and b0 <= 0x7A:
                    c -= 32
            else:
                if b0 >= 0x41 and b0 <= 0x5A:
                    c += 32
            out.append(UInt8(c))
            i += 1
            continue
        var seq = _utf8_seq_len(b0)
        # Not a lead byte, or a sequence running off the end of the buffer:
        # copy ONE byte and resynchronise. Never raise, never substitute.
        if seq == 0 or i + seq > n:
            out.append(b0)
            i += 1
            continue
        var cp: Int
        if seq == 2:
            cp = Int(b0) & 0x1F
        elif seq == 3:
            cp = Int(b0) & 0x0F
        else:
            cp = Int(b0) & 0x07
        var ok = True
        for k in range(1, seq):
            var bk = b[i + k]
            if (bk & 0xC0) != 0x80:
                ok = False
                break
            cp = (cp << 6) | (Int(bk) & 0x3F)
        # A lead byte whose continuations are missing is malformed: emit the
        # lead alone and rescan from the next byte, so the bytes that DID
        # decode are not swallowed with it.
        if not ok:
            out.append(b0)
            i += 1
            continue
        # Overlong encodings and the surrogate block decode to a scalar value
        # the table would happily map, which would REWRITE bytes on malformed
        # input. Pass the original bytes through untouched instead.
        var overlong = (
            (seq == 3 and cp < 0x800)
            or (seq == 4 and cp < 0x10000)
            or (cp >= 0xD800 and cp <= 0xDFFF)
            or cp > 0x10FFFF
        )
        if overlong:
            for k in range(seq):
                out.append(b[i + k])
            i += seq
            continue
        var mapped = simple_upper_cp(cp) if to_upper else simple_lower_cp(cp)
        if mapped == cp:
            # Unchanged: copy the original bytes rather than re-encoding, so a
            # cased-but-unmapped codepoint costs nothing.
            for k in range(seq):
                out.append(b[i + k])
        else:
            _encode_utf8_into(mapped, out)
        i += seq
    return out^


def unicode_upper_bytes(s: String) -> List[UInt8]:
    """`upper(s)` — DuckDB v1.5.3 parity over every codepoint. Returns BYTES;
    pair with `StringArray.from_byte_lists`, never `from_strings`."""
    return _case_fold_bytes[True](s)


def unicode_lower_bytes(s: String) -> List[UInt8]:
    """`lower(s)` — DuckDB v1.5.3 parity over every codepoint. Returns BYTES;
    pair with `StringArray.from_byte_lists`, never `from_strings`."""
    return _case_fold_bytes[False](s)
