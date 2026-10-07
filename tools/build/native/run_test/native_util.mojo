# Pure helpers of the run test's programs (native_run.sh): hex, byte
# comparison and the CHECK line. They call no C, so a program that dlopens
# the library (native_dlopen.mojo) can import them without linking it.


def _nibble(c: UInt8) -> UInt8:
    if c >= UInt8(0x30) and c <= UInt8(0x39):
        return c - UInt8(0x30)
    return c - UInt8(0x61) + UInt8(10)


def from_hex(s: String) -> List[UInt8]:
    var bs = s.as_bytes()
    var out = List[UInt8](capacity=len(bs) // 2)
    for i in range(len(bs) // 2):
        out.append((_nibble(bs[2 * i]) << UInt8(4)) | _nibble(bs[2 * i + 1]))
    return out^


def bytes_of(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var src = s.as_bytes()
    for i in range(len(src)):
        out.append(src[i])
    return out^


def _hexd(v: Int) -> String:
    if v < 10:
        return chr(0x30 + v)
    return chr(0x61 + v - 10)


def hex_of(b: Span[UInt8, _]) -> String:
    var out = String()
    for i in range(len(b)):
        out += _hexd(Int(b[i]) >> 4)
        out += _hexd(Int(b[i]) & 0xF)
    return out^


def same(a: Span[UInt8, _], b: Span[UInt8, _]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def report(name: String, ok: Bool, detail: String) -> Bool:
    print("CHECK", name, "PASS" if ok else "FAIL", detail, flush=True)
    return ok
