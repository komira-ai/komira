# =============================================================================
# komira_grpc/routing.mojo — `(google.api.routing)` header construction.
# =============================================================================
#
# The pure-string runtime for the `x-goog-request-params` routing header that
# Google's gRPC frontend requires (a call lacking it gets `grpc-status: 3`
# "An x-goog-request-params request metadata property must be provided").
#
# The protoc code generator's emitter generates, in
# each `(google.api.routing)`-annotated gRPC client method, code that:
#   1. reads each routing-parameter field off the request message,
#   2. calls `match_path_template(field_value, path_template)` to extract the
#      captured substring (None if the value does not match the template),
#   3. on a match, pushes a `(key, captured_value)` pair (key resolved by the
#      emitter from the template's `{key=...}` named capture, or the field
#      name for the whole-field fallback),
#   4. calls `build_routing_params(pairs)` to percent-encode + `&`-join the
#      pairs into the ONE header value, and sets it on
#      `opts.raw_metadata` under `x-goog-request-params`.
#
# This module is the matcher + joiner. It is a PURE string algorithm — NO
# UnsafePointer, no pointers across boundaries (the encapsulation rule). The
# path-template grammar mirrors `google.api.routing` (a subset of the
# `google.api.http` template grammar used for routing):
#
#   path_template = segment { "/" segment }
#   segment       = literal | "*" | "**" | "{" name "=" subpattern "}"
#   subpattern    = segment { "/" segment }   (no nested braces)
#
#   *   matches exactly one `/`-delimited segment
#   **  matches zero-or-more trailing segments
#   {name=subpattern} is a NAMED capture: the captured value is the substring
#       matched by `subpattern`; the header key is `name` (resolved at emit
#       time by the emitter, NOT here).
#
# A template with NO `{...}` binding is the whole-field fallback: the emitter
# passes the empty string for `path_template`, and the value is the whole
# field (key = field name, supplied by the emitter).
# =============================================================================


def build_routing_params(pairs: List[Tuple[StaticString, String]]) -> String:
    """Join the `(key, value)` routing pairs into the ONE
    `x-goog-request-params` header value: `key1=value1&key2=value2`.

    Both keys and values are percent-encoded (the values can contain `/` and
    other reserved characters). Pairs join with `&` in the order given. The
    key is a `StaticString` (an emitter-supplied literal); the value is a
    runtime `String` (the captured substring). An empty `pairs` returns the
    empty string (the emitter then skips setting the header).

    A pair whose value is EMPTY is dropped before anything else, as Google's
    generated clients drop an empty capture: `{project=**}` matches the empty
    string (`**` is zero or more segments), and sending `project=` would both
    route nowhere and, under last-match-wins, overwrite an earlier non-empty
    match for the same key (GCS CreateBucket: `parent = "projects/_"` and a
    `bucket` whose `project` is unset)."""
    # De-duplicate by key with LAST-match-wins (the google.api.routing semantics).
    # When several routing_parameters resolve to the SAME key — e.g. GCS
    # CreateBucket, whose `parent` and `bucket.project` BOTH key `project` — the
    # LAST match takes precedence. Emitting BOTH produces a duplicate-key header the
    # Google frontend rejects with grpc:3 "The x-goog-request-params metadata has
    # duplicate entries for the key '<k>'". Keys are emitted in first-seen order; the
    # value carried is the last-seen one for that key. (Distinct-key headers are
    # unaffected — de-dup of unique keys is a no-op.)
    var keys = List[String]()
    var vals = List[String]()
    for i in range(len(pairs)):
        ref pair = pairs[i]
        if pair[1].byte_length() == 0:
            continue
        var k = String(pair[0])
        var found = -1
        for j in range(len(keys)):
            if keys[j] == k:
                found = j
                break
        if found >= 0:
            vals[found] = pair[1].copy()
        else:
            keys.append(k^)
            vals.append(pair[1].copy())

    var out = String("")
    for i in range(len(keys)):
        if i > 0:
            out += "&"
        out += _percent_encode(keys[i])
        out += "="
        out += _percent_encode(vals[i])
    return out


def match_path_template(
    field_value: String, path_template: String
) -> Optional[String]:
    """Match `field_value` against `path_template`; on success return the
    substring captured by the template's `{name=subpattern}` named segment.

    The WHOLE `field_value` must match the WHOLE template (segments before,
    inside, and after the brace). On a mismatch return `None` (the emitter
    then sends nothing for this parameter — sending garbage pollutes routing
    cache, so the spec mandates the match).

    Whole-field fallback: an EMPTY `path_template` returns the whole
    `field_value` unconditionally (the key is the field name, supplied by the
    emitter). This mirrors the spec's `{field=**}` shorthand.

    A template with no `{...}` binding (a pure literal/wildcard guard) returns
    the whole `field_value` on a match — but in practice every routing
    template carries exactly one named capture, so this is the fallback path.
    """
    # Whole-field fallback — the emitter passes "" for a bare `field`.
    if path_template.byte_length() == 0:
        return Optional[String](field_value)

    var value_segs = _split_segments(field_value)
    var tmpl_segs = _split_template_segments(path_template)

    # Find the single `{name=subpattern}` segment (if any). The grammar
    # guarantees AT MOST one named capture per template.
    var capture_idx = -1
    for i in range(len(tmpl_segs)):
        if _is_named_capture(tmpl_segs[i]):
            capture_idx = i
            break

    if capture_idx < 0:
        # No named capture: a pure literal/wildcard template. Match the whole
        # value; on success the captured value is the whole field.
        var lo = -1
        var hi = -1
        if _match_record(value_segs, tmpl_segs, -1, -1, lo, hi):
            return Optional[String](field_value)
        return Optional[String]()

    # Expand the named capture's subpattern in place so the template becomes a
    # flat segment list, and record the [start, after) sub-range the capture's
    # subpattern occupies (its matched value-segments are the captured value).
    var subpattern = _capture_subpattern(tmpl_segs[capture_idx])
    var sub_segs = _split_segments(subpattern)

    var flat = List[String]()
    for i in range(capture_idx):
        flat.append(tmpl_segs[i])
    var cap_start = len(flat)
    for i in range(len(sub_segs)):
        flat.append(sub_segs[i])
    var cap_after = len(flat)
    for i in range(capture_idx + 1, len(tmpl_segs)):
        flat.append(tmpl_segs[i])

    var v_lo = -1
    var v_hi = -1
    if not _match_record(value_segs, flat, cap_start, cap_after, v_lo, v_hi):
        return Optional[String]()

    # Reassemble the captured value from value_segs[v_lo : v_hi].
    var captured = String("")
    for i in range(v_lo, v_hi):
        if i > v_lo:
            captured += "/"
        captured += value_segs[i]
    return Optional[String](captured)


# =============================================================================
# Internal segment matcher.
# =============================================================================


def _split_segments(s: String) -> List[String]:
    """Split `s` on `/` into segments. A single leading `/` (absolute form)
    yields no leading empty segment; an empty string yields an empty list.
    Operates byte-wise (segment boundaries are ASCII `/`) through
    `as_bytes()`: a field value may be any UTF-8 text (a GCS object name),
    and indexing `s[byte=i]` asserts on a continuation byte and aborts the
    process. A cut at an ASCII `/` keeps each segment valid UTF-8."""
    var out = List[String]()
    var bytes = s.as_bytes()
    var n = len(bytes)
    if n == 0:
        return out^
    var cur = List[UInt8]()
    for i in range(n):
        var b = bytes[i]
        if b == UInt8(ord("/")):
            out.append(String(unsafe_from_utf8=Span(cur)))
            cur = List[UInt8]()
        else:
            cur.append(b)
    out.append(String(unsafe_from_utf8=Span(cur)))
    # Drop a single leading empty segment from an absolute "/a/b" form.
    if len(out) > 0 and out[0].byte_length() == 0:
        var trimmed = List[String]()
        for i in range(1, len(out)):
            trimmed.append(out[i])
        return trimmed^
    return out^


def _split_template_segments(s: String) -> List[String]:
    """Split a path_TEMPLATE on `/` into segments, but treat a `/` that lives
    INSIDE a `{name=subpattern}` named capture as a literal (a named capture
    whose subpattern contains `/` — e.g. `{project=projects/*}` — is ONE
    segment, not three). Only `/` at brace-depth 0 is a segment boundary.

    Unlike `_split_segments` (used for VALUES and capture-subpatterns, neither
    of which contains braces), this is brace-aware so it must only be applied
    to the template. The grammar forbids nested braces, so depth is 0 or 1.
    Leading-empty-segment trimming and the empty-input case match
    `_split_segments`. Byte-wise through `as_bytes()`, as there."""
    var out = List[String]()
    var bytes = s.as_bytes()
    var n = len(bytes)
    if n == 0:
        return out^
    var cur = List[UInt8]()
    var depth = 0
    for i in range(n):
        var b = bytes[i]
        if b == UInt8(ord("{")):
            depth += 1
            cur.append(b)
        elif b == UInt8(ord("}")):
            if depth > 0:
                depth -= 1
            cur.append(b)
        elif b == UInt8(ord("/")) and depth == 0:
            out.append(String(unsafe_from_utf8=Span(cur)))
            cur = List[UInt8]()
        else:
            cur.append(b)
    out.append(String(unsafe_from_utf8=Span(cur)))
    # Drop a single leading empty segment from an absolute "/a/b" form.
    if len(out) > 0 and out[0].byte_length() == 0:
        var trimmed = List[String]()
        for i in range(1, len(out)):
            trimmed.append(out[i])
        return trimmed^
    return out^


def _is_named_capture(seg: String) -> Bool:
    """True iff `seg` is a `{name=subpattern}` named-capture segment."""
    var bytes = seg.as_bytes()
    var n = len(bytes)
    if n < 2:
        return False
    if bytes[0] != UInt8(ord("{")):
        return False
    if bytes[n - 1] != UInt8(ord("}")):
        return False
    return _index_of_eq(seg) >= 0


def _capture_subpattern(seg: String) -> String:
    """Extract the `subpattern` from a `{name=subpattern}` segment — the bytes
    after the first `=`, before the closing `}`."""
    var eq = _index_of_eq(seg)
    var bytes = seg.as_bytes()
    var inner = List[UInt8]()
    for i in range(eq + 1, len(bytes) - 1):
        inner.append(bytes[i])
    return String(unsafe_from_utf8=Span(inner))


def _index_of_eq(s: String) -> Int:
    """Byte index of the first `=` in `s`, or -1."""
    var bytes = s.as_bytes()
    for i in range(len(bytes)):
        if bytes[i] == UInt8(ord("=")):
            return i
    return -1


def _match_record(
    value_segs: List[String],
    tmpl_segs: List[String],
    cap_start: Int,
    cap_after: Int,
    mut v_lo: Int,
    mut v_hi: Int,
) -> Bool:
    """Match the FULL `value_segs` against the FULL `tmpl_segs` under the
    grammar (literal == literal, `*` == one segment, `**` == zero-or-more
    trailing segments). When `cap_start <= t < cap_after`, the value segments
    that template index `t` consumes are recorded into [v_lo, v_hi) — the
    captured value's segment range.

    Returns True iff the whole value matches the whole template. A `**` is
    supported only as a trailing template segment (the published
    `google.api.routing` templates only use trailing `**`), matching all remaining
    value segments greedily."""
    var vi = 0
    var ti = 0
    var nv = len(value_segs)
    var nt = len(tmpl_segs)
    var recording = cap_start >= 0
    v_lo = -1
    v_hi = -1

    while ti < nt:
        var t = tmpl_segs[ti]
        var in_capture = recording and ti >= cap_start and ti < cap_after

        if t == "**":
            # `**` matches all remaining value segments (a trailing
            # wildcard). Record from here to the end if captured.
            if in_capture:
                if v_lo < 0:
                    v_lo = vi
                v_hi = nv
            vi = nv
            ti += 1
            continue

        # A `*` or a literal consumes exactly one value segment.
        if vi >= nv:
            return False
        if t == "*":
            pass  # `*` matches any single segment.
        elif t != value_segs[vi]:
            return False
        if in_capture:
            if v_lo < 0:
                v_lo = vi
            v_hi = vi + 1
        vi += 1
        ti += 1

    # The whole value must be consumed.
    return vi == nv


def _percent_encode(s: String) -> String:
    """RFC 6570 simple-string percent-encoding: escape every byte EXCEPT the
    unreserved set `A-Z a-z 0-9 - . _ ~`. This is the encoding
    `google.api.routing` mandates for the header key+value (the values can
    contain `/`, which MUST be escaped to `%2F`). Output is ASCII-only.

    Per BYTE, through `as_bytes()`: `é` is `%C3%A9`. (Indexing `s[byte=i]`
    asserts on a UTF-8 continuation byte and aborts the process.)"""
    var out = List[UInt8]()
    var bytes = s.as_bytes()
    var n = len(bytes)
    for i in range(n):
        var b = Int(bytes[i])
        if _is_unreserved(b):
            out.append(UInt8(b))
        else:
            out.append(UInt8(ord("%")))
            out.append(_hex_upper((b >> 4) & 0x0F))
            out.append(_hex_upper(b & 0x0F))
    return String(unsafe_from_utf8=Span(out))


def _hex_upper(nibble: Int) -> UInt8:
    """A 4-bit value to its uppercase-hex ASCII byte (`0`..`F`)."""
    if nibble < 10:
        return UInt8(ord("0") + nibble)
    return UInt8(ord("A") + nibble - 10)


def _is_unreserved(b: Int) -> Bool:
    """The RFC 6570 unreserved set: `A-Z a-z 0-9 - . _ ~`."""
    if b >= ord("0") and b <= ord("9"):
        return True
    if b >= ord("A") and b <= ord("Z"):
        return True
    if b >= ord("a") and b <= ord("z"):
        return True
    if b == ord("-") or b == ord(".") or b == ord("_") or b == ord("~"):
        return True
    return False
