# komira_credential_add, komira_credential_set, komira_credential_seal: a
# credential defined on a session, and the named error a wrong one gives.
#
# Rows: an AwsKeys credential added, given its two fields and sealed is 0 at
# each step with no error, and the id is written; an AwsKeys credential sealed
# without its secret is -3 with the last error, word for word,
# `CREDENTIALS_INVALID: seal credential=raw-etl: AwsKeys needs secret=`, and
# its id is closed after (a seal of it is -3 naming the id); a field of
# another kind (token= on AwsKeys) is -3 naming it, and the value set is
# nowhere in the error; an unknown kind and the name `ambient` are -3 with the
# id slot untouched; a name outside the grammar is -3 and is not quoted, and
# a name that is not UTF-8 is -3 with its own named error; a value of 4097
# bytes is -3 naming the 4096-byte bound; a
# NULL context is -1 for each call; a NULL name or out_id is -2 with the id
# slot untouched; a NULL value with a non-zero length is -2, and with length
# 0 it is an empty value (-3, `secret= is empty`); a value_len of 64 MiB plus
# one is -5 and nothing is read; a scope other than KOMIRA_BIND_SESSION is -3;
# a good call after a refusal clears the error.
#
# A gate driver of //src/so:libkomira. It has no dependency: it opens
# the library with dlopen (RTLD_NOW, through OwnedDLHandle) and calls the
# C symbols as a foreign host would. A context handle, a string, a buffer and
# the id slot are passed as the integer word of their address (a pointer and
# an Int are passed the same way on both supported targets); NULL is the word
# 0.

from std.ffi import OwnedDLHandle
from std.memory import alloc
from std.sys import CompilationTarget

comptime LIB = "./libkomira.dylib" if CompilationTarget.is_macos() else "./libkomira.so"
comptime CAP = 4096
comptime UNTOUCHED = Int32(-7)

# The constants of komira.h this driver uses.
comptime BIND_SESSION = Int32(1)
comptime CRED_AWS_KEYS = Int32(1)
comptime FIELD_KEY_ID = Int32(1)
comptime FIELD_SECRET = Int32(2)
comptime FIELD_TOKEN = Int32(6)
comptime MAX_INPUT_BYTES = UInt64(64 * 1024 * 1024)


def _expect(ok: Bool, what: String) raises:
    if not ok:
        raise Error(what)


def _cstr(s: String) -> Int:
    # The address of a NUL-terminated copy of `s`. It is not freed: the driver
    # is a short-lived process and holds a handful of these.
    var b = s.as_bytes()
    var p = alloc[UInt8](len(b) + 1)
    for i in range(len(b)):
        p[i] = b[i]
    p[len(b)] = UInt8(0)
    return Int(p)


def _last_error(lib: OwnedDLHandle, ctx: Int) raises -> String:
    # SAFETY: allocated here and freed below; the library writes the 8 bytes of
    # `out_len` and at most CAP bytes of `buf`.
    var out_len = alloc[UInt64](1)
    var buf = alloc[UInt8](CAP)
    var rc = lib.call["komira_last_error", Int32](ctx, buf, UInt64(CAP), out_len)
    _expect(rc == 0, "komira_last_error returned " + String(rc))
    var text = List[UInt8]()
    for i in range(Int(out_len[0])):
        text.append(buf[i])
    buf.free()
    out_len.free()
    return String(unsafe_from_utf8=Span(text))


def _add(lib: OwnedDLHandle, ctx: Int, kind: Int32, name: Int, out_id: Int) raises -> Int32:
    return lib.call["komira_credential_add", Int32](ctx, kind, name, out_id)


def _set(lib: OwnedDLHandle, ctx: Int, id: Int32, field: Int32, value: Int, n: UInt64) raises -> Int32:
    return lib.call["komira_credential_set", Int32](ctx, id, field, value, n)


def _set_text(lib: OwnedDLHandle, ctx: Int, id: Int32, field: Int32, text: String) raises -> Int32:
    return _set(lib, ctx, id, field, _cstr(text), UInt64(text.byte_length()))


def _seal(lib: OwnedDLHandle, ctx: Int, id: Int32, scope: Int32) raises -> Int32:
    return lib.call["komira_credential_seal", Int32](ctx, id, scope)


def main() raises:
    var lib = OwnedDLHandle(LIB)
    var ctx = lib.call["komira_ctx_new", Int]()
    _expect(ctx != 0, "komira_ctx_new returned NULL")
    var name_c = _cstr(String("raw-etl"))
    var id_slot = alloc[Int32](1)
    var id_p = Int(id_slot)

    # A good definition: add, set both fields, seal.
    id_slot[0] = UNTOUCHED
    _expect(_add(lib, ctx, CRED_AWS_KEYS, name_c, id_p) == 0, "a good add was refused")
    var good = id_slot[0]
    _expect(good != UNTOUCHED, "a good add wrote no id")
    _expect(_set_text(lib, ctx, good, FIELD_KEY_ID, "AKIDGATE") == 0, "a good key_id was refused")
    _expect(_set_text(lib, ctx, good, FIELD_SECRET, "gate-secret-value") == 0, "a good secret was refused")
    _expect(_seal(lib, ctx, good, BIND_SESSION) == 0, "a good seal was refused")
    _expect(_last_error(lib, ctx) == "", "a good definition left an error")

    # Wrong: sealed without its secret. The named error, word for word.
    _expect(_add(lib, ctx, CRED_AWS_KEYS, name_c, id_p) == 0, "the second add was refused")
    var partial = id_slot[0]
    _expect(_set_text(lib, ctx, partial, FIELD_KEY_ID, "AKIDGATE") == 0, "key_id was refused")
    _expect(_seal(lib, ctx, partial, BIND_SESSION) == -3, "a seal without secret= is not -3")
    var missing = _last_error(lib, ctx)
    _expect(
        missing == "CREDENTIALS_INVALID: seal credential=raw-etl: AwsKeys needs secret=",
        "a seal without secret= gave: " + missing,
    )
    _expect(_seal(lib, ctx, partial, BIND_SESSION) == -3, "a refused definition was sealed again")
    var closed = _last_error(lib, ctx)
    _expect(
        closed
        == "CREDENTIALS_INVALID: seal credential: id " + String(partial) + " is not an open definition",
        "a closed id gave: " + closed,
    )

    # Wrong: a field of another kind. The value is nowhere in the error.
    _expect(_add(lib, ctx, CRED_AWS_KEYS, name_c, id_p) == 0, "the third add was refused")
    var other = id_slot[0]
    _expect(_set_text(lib, ctx, other, FIELD_TOKEN, "tok-should-not-leak") == -3, "token= on AwsKeys is not -3")
    var wrong_field = _last_error(lib, ctx)
    _expect(
        wrong_field == "CREDENTIALS_INVALID: set credential=raw-etl: AwsKeys has no token=",
        "token= on AwsKeys gave: " + wrong_field,
    )

    # Wrong kind, reserved and malformed names: -3, the id slot untouched.
    id_slot[0] = UNTOUCHED
    _expect(_add(lib, ctx, Int32(99), name_c, id_p) == -3, "kind 99 is not -3")
    _expect(id_slot[0] == UNTOUCHED, "a refused add wrote the id")
    _expect(
        _last_error(lib, ctx) == "CREDENTIALS_INVALID: add credential: kind 99 is not a KOMIRA_CRED_* kind",
        "kind 99 gave another error",
    )
    _expect(_add(lib, ctx, CRED_AWS_KEYS, _cstr(String("ambient")), id_p) == -3, "ambient is not -3")
    _expect(id_slot[0] == UNTOUCHED, "a refused ambient wrote the id")
    _expect(
        _add(lib, ctx, CRED_AWS_KEYS, _cstr(String("AKIA/pasted secret")), id_p) == -3,
        "a malformed name is not -3",
    )
    var bad_name = _last_error(lib, ctx)
    _expect(
        bad_name
        == "CREDENTIALS_INVALID: add credential: the name is not 1 to 128 bytes of letters, digits, '_', '.' and '-'",
        "a malformed name gave: " + bad_name,
    )

    var not_utf8 = alloc[UInt8](3)
    not_utf8[0] = UInt8(0x61)
    not_utf8[1] = UInt8(0xFF)
    not_utf8[2] = UInt8(0)
    _expect(_add(lib, ctx, CRED_AWS_KEYS, Int(not_utf8), id_p) == -3, "a name that is not UTF-8 is not -3")
    _expect(id_slot[0] == UNTOUCHED, "a refused non-UTF-8 name wrote the id")
    _expect(
        _last_error(lib, ctx) == "CREDENTIALS_INVALID: add credential: the name is not UTF-8",
        "a name that is not UTF-8 gave another error",
    )

    # A value one byte past the 4096-byte bound.
    _expect(_add(lib, ctx, CRED_AWS_KEYS, name_c, id_p) == 0, "the add before a long value was refused")
    var long_value = String("")
    for _ in range(4097):
        long_value += "s"
    _expect(_set_text(lib, ctx, id_slot[0], FIELD_SECRET, long_value) == -3, "a 4097-byte value is not -3")
    _expect(
        _last_error(lib, ctx) == "CREDENTIALS_INVALID: set credential=raw-etl: secret= is longer than 4096 bytes",
        "a 4097-byte value gave another error",
    )

    # NULL arguments.
    id_slot[0] = UNTOUCHED
    _expect(_add(lib, 0, CRED_AWS_KEYS, name_c, id_p) == -1, "add with NULL ctx is not -1")
    _expect(_set(lib, 0, good, FIELD_SECRET, 0, UInt64(0)) == -1, "set with NULL ctx is not -1")
    _expect(_seal(lib, 0, good, BIND_SESSION) == -1, "seal with NULL ctx is not -1")
    _expect(_add(lib, ctx, CRED_AWS_KEYS, 0, id_p) == -2, "add with NULL name is not -2")
    _expect(_last_error(lib, ctx) != "", "add with NULL name stored no error")
    _expect(_add(lib, ctx, CRED_AWS_KEYS, name_c, 0) == -2, "add with NULL out_id is not -2")
    _expect(id_slot[0] == UNTOUCHED, "a NULL-argument add wrote the id")

    _expect(_add(lib, ctx, CRED_AWS_KEYS, name_c, id_p) == 0, "the fourth add was refused")
    var nulls = id_slot[0]
    _expect(_set(lib, ctx, nulls, FIELD_SECRET, 0, UInt64(3)) == -2, "NULL value with length 3 is not -2")
    _expect(_last_error(lib, ctx) != "", "a NULL value stored no error")
    # A 3-byte buffer with a length past the bound: -5 and nothing read.
    var small = _cstr(String("abc"))
    _expect(
        _set(lib, ctx, nulls, FIELD_SECRET, small, MAX_INPUT_BYTES + UInt64(1)) == -5,
        "value_len above 64 MiB is not -5",
    )
    _expect(_set(lib, ctx, nulls, FIELD_SECRET, 0, UInt64(0)) == -3, "an empty value is not -3")
    _expect(
        _last_error(lib, ctx) == "CREDENTIALS_INVALID: set credential=raw-etl: secret= is empty",
        "an empty value gave another error",
    )

    # A scope other than KOMIRA_BIND_SESSION.
    _expect(_add(lib, ctx, CRED_AWS_KEYS, name_c, id_p) == 0, "the fifth add was refused")
    var scoped = id_slot[0]
    _expect(_set_text(lib, ctx, scoped, FIELD_KEY_ID, "AKIDGATE") == 0, "key_id was refused")
    _expect(_set_text(lib, ctx, scoped, FIELD_SECRET, "gate-secret-value") == 0, "secret was refused")
    _expect(_seal(lib, ctx, scoped, Int32(2)) == -3, "scope 2 is not -3")
    _expect(
        _last_error(lib, ctx) == "CREDENTIALS_INVALID: seal credential=raw-etl: scope 2 is not KOMIRA_BIND_SESSION",
        "scope 2 gave another error",
    )

    # A good call after a refusal clears the error.
    _expect(_add(lib, ctx, CRED_AWS_KEYS, name_c, id_p) == 0, "an add after a refusal was refused")
    _expect(_last_error(lib, ctx) == "", "the earlier error was not cleared")

    id_slot.free()
    lib.call["komira_ctx_free", NoneType](ctx)
    print("ok")
