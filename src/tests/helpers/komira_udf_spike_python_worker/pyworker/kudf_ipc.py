"""The Arrow IPC subset the Python worker reads and writes, without pyarrow.

The engine side (native/ipc_codec.c) writes Schema messages (LOAD and
VALIDATE) and RecordBatch messages of fixed-width columns (CALL_BATCH); the
worker reads both here, and writes one-column RecordBatch messages back.
Every offset and size read is checked against the message, and a reader
error raises IpcError naming what is wrong.

A message is the IPC encapsulation: 0xFFFFFFFF, the metadata length, the
flatbuffer (a Message table whose header is a Schema or a RecordBatch),
padding, then the body. Written messages pad the metadata so the body starts
on a 64-byte boundary, and start each body buffer on one.
"""

import struct

ALIGN = 64

# Arrow's Type union members this codec maps to a C Data format.
_T_NULL, _T_INT, _T_FLOAT, _T_BINARY, _T_UTF8, _T_BOOL = 1, 2, 3, 4, 5, 6
_INT_FORMAT = {
    (8, True): "c", (8, False): "C", (16, True): "s", (16, False): "S",
    (32, True): "i", (32, False): "I", (64, True): "l", (64, False): "L",
}
_FLOAT_FORMAT = {0: "e", 1: "f", 2: "g"}

_u8 = struct.Struct("<B").unpack_from
_u16 = struct.Struct("<H").unpack_from
_i16 = struct.Struct("<h").unpack_from
_u32 = struct.Struct("<I").unpack_from
_i32 = struct.Struct("<i").unpack_from
_i64 = struct.Struct("<q").unpack_from
_node = struct.Struct("<qq").unpack_from


class IpcError(Exception):
    pass


class _Reader:
    """Flatbuffer reads within [base, base + size) of `buf`."""

    __slots__ = ("b", "base", "end")

    def __init__(self, buf, base, size):
        self.b = buf
        self.base = base
        self.end = base + size

    def need(self, at, n):
        if at < self.base or at + n > self.end:
            raise IpcError("a flatbuffer read at {} runs past the metadata".format(at - self.base))

    def u32(self, at):
        self.need(at, 4)
        return _u32(self.b, at)[0]

    def deref(self, at):
        return at + self.u32(at)

    def field(self, t, fid):
        """The position of field `fid` of the table at `t`, or None."""
        self.need(t, 4)
        vt = t - _i32(self.b, t)[0]
        self.need(vt, 4)
        vsize, tsize = _u16(self.b, vt)[0], _u16(self.b, vt + 2)[0]
        slot = 4 + 2 * fid
        if slot + 2 > vsize:
            return None
        self.need(vt + slot, 2)
        off = _u16(self.b, vt + slot)[0]
        if off == 0:
            return None
        if off >= tsize:
            raise IpcError("a field offset past its table")
        return t + off

    def vector(self, t, fid, elem):
        """(first element, count) of a vector field; (0, 0) when absent."""
        f = self.field(t, fid)
        if f is None:
            return 0, 0
        v = self.deref(f)
        n = self.u32(v)
        self.need(v + 4, n * elem)
        return v + 4, n

    def string(self, t, fid):
        f = self.field(t, fid)
        if f is None:
            return ""
        s = self.deref(f)
        n = self.u32(s)
        self.need(s + 4, n)
        return bytes(self.b[s + 4 : s + 4 + n]).decode("utf-8")


def _message(buf, at, limit):
    """(reader, Message table, header type, header table, body start, body
    length) of the encapsulated message at `at`, within `limit` bytes."""
    if limit < 8:
        raise IpcError("a message shorter than its prefix")
    cont, meta = _u32(buf, at)[0], _i32(buf, at + 4)[0]
    if cont != 0xFFFFFFFF:
        raise IpcError("a message without the continuation marker")
    if meta <= 0 or meta % 8 or meta > limit - 8:
        raise IpcError("a metadata length outside the message")
    r = _Reader(buf, at + 8, meta)
    m = r.deref(at + 8)
    fv, fh, fb, fl = r.field(m, 0), r.field(m, 1), r.field(m, 2), r.field(m, 3)
    if fv is None or _i16(buf, fv)[0] != 4:
        raise IpcError("the message is not metadata version V5")
    htype = _u8(buf, fh)[0] if fh is not None else 0
    if fb is None:
        raise IpcError("a message without a header")
    body_len = _i64(buf, fl)[0] if fl is not None else 0
    body = at + 8 + meta
    if body_len < 0 or body_len > limit - 8 - meta:
        raise IpcError("the body runs past the message")
    return r, m, htype, r.deref(fb), body, body_len


def read_schema(buf, at, limit):
    """([(name, format, nullable)], bytes the message takes) of a Schema
    message. A type outside this codec's set has format "?<type id>"."""
    r, _, htype, sch, body, body_len = _message(buf, at, limit)
    if htype != 1:
        raise IpcError("the message is not a schema")
    first, n = r.vector(sch, 1, 4)
    fields = []
    for i in range(n):
        f = r.deref(first + 4 * i)
        name = r.string(f, 0)
        fn = r.field(f, 1)
        nullable = bool(_u8(buf, fn)[0]) if fn is not None else False
        ft = r.field(f, 2)
        tt = _u8(buf, ft)[0] if ft is not None else 0
        tf = r.field(f, 3)
        t = r.deref(tf) if tf is not None else None
        fmt = "?{}".format(tt)
        if tt == _T_INT and t is not None:
            bw, sg = r.field(t, 0), r.field(t, 1)
            bits = _i32(buf, bw)[0] if bw is not None else 0
            signed = bool(_u8(buf, sg)[0]) if sg is not None else False
            fmt = _INT_FORMAT.get((bits, signed), fmt)
        elif tt == _T_FLOAT and t is not None:
            pr = r.field(t, 0)
            fmt = _FLOAT_FORMAT.get(_i16(buf, pr)[0] if pr is not None else 0, fmt)
        elif tt in (_T_NULL, _T_BINARY, _T_UTF8, _T_BOOL):
            fmt = {_T_NULL: "n", _T_BINARY: "z", _T_UTF8: "u", _T_BOOL: "b"}[tt]
        fields.append((name, fmt, nullable))
    return fields, body - at + body_len


def read_batch(buf, at, limit, widths):
    """(length, [(values offset, validity offset or None, null count)]) of a
    RecordBatch message of fixed-width columns, `widths[i]` bytes per value;
    offsets are positions in `buf`. Each buffer is checked to lie in the
    body and to hold the column's rows."""
    r, _, htype, rb, body, body_len = _message(buf, at, limit)
    if htype != 3:
        raise IpcError("the message is not a record batch")
    fl = r.field(rb, 0)
    length = _i64(buf, fl)[0] if fl is not None else 0
    nodes, nn = r.vector(rb, 1, 16)
    bufs, nb = r.vector(rb, 2, 16)
    if r.field(rb, 3) is not None:
        raise IpcError("a compressed record batch")
    if nn != len(widths) or nb != 2 * nn:
        raise IpcError("{} columns and {} buffers; the schema has {} columns".format(nn, nb, len(widths)))
    if length < 0:
        raise IpcError("a negative batch length")
    cols = []
    for i, w in enumerate(widths):
        clen, nulls = _node(buf, nodes + 16 * i)
        voff, vlen = _node(buf, bufs + 32 * i)
        doff, dlen = _node(buf, bufs + 32 * i + 16)
        if clen != length:
            raise IpcError("column {} has {} rows, the batch {}".format(i, clen, length))
        if nulls < 0 or nulls > length:
            raise IpcError("column {}: null count outside 0 .. length".format(i))
        for o, n in ((voff, vlen), (doff, dlen)):
            if o < 0 or n < 0 or o + n > body_len:
                raise IpcError("column {}: a buffer runs past the body".format(i))
        if dlen < length * w:
            raise IpcError("column {}: the values buffer is shorter than its rows".format(i))
        if nulls and vlen < (length + 7) // 8:
            raise IpcError("column {}: the validity bitmap is shorter than its rows".format(i))
        cols.append((body + doff, body + voff if nulls else None, nulls))
    return length, cols


# ---- writing ------------------------------------------------------------------


class _Builder:
    """Front-to-back flatbuffer writing, as ipc_codec.c does it."""

    def __init__(self):
        self.b = bytearray()

    def zero(self, n):
        self.b += bytes(n)

    def align(self, a, mod=0):
        while len(self.b) % a != mod:
            self.b.append(0)

    def table(self, fields):
        """fields: [(id, size, value or None for an offset)]; returns (table
        position, {id: field position})."""
        max_id = max([f[0] for f in fields], default=-1)
        has8 = any(f[1] == 8 for f in fields)
        rel = {}
        tsize = 4
        for s in (8, 4, 2, 1):
            for fid, size, _ in fields:
                if size == s:
                    rel[fid] = tsize
                    tsize += size
        self.align(2)
        vt = len(self.b)
        vsize = 4 + 2 * (max_id + 1)
        t = vt + vsize
        while (t % 8 != 4) if has8 else (t % 4 != 0):
            t += 1
        self.b += struct.pack("<HH", vsize, tsize)
        for fid in range(max_id + 1):
            self.b += struct.pack("<H", rel.get(fid, 0))
        self.zero(t - len(self.b))
        self.b += struct.pack("<i", t - vt)
        self.zero(tsize - 4)
        pos = {}
        for fid, size, value in fields:
            pos[fid] = t + rel[fid]
            if value is not None:
                struct.pack_into({1: "<B", 2: "<h", 4: "<i", 8: "<q"}[size], self.b, pos[fid], value)
        return t, pos

    def patch(self, at, target):
        struct.pack_into("<I", self.b, at, target - at)

    def structs(self, data, count):
        while (len(self.b) + 4) % 8:
            self.b.append(0)
        p = len(self.b)
        self.b += struct.pack("<I", count) + data
        return p


class BatchWriter:
    """Writes one-column RecordBatch messages. The metadata's layout does not
    depend on the values, so it is built once and each batch patches its
    numbers in place."""

    def __init__(self):
        fb = _Builder()
        fb.zero(4)
        mt, m = fb.table([(0, 2, 4), (1, 1, 3), (2, 4, None), (3, 8, 0)])
        fb.patch(0, mt)
        rt, r = fb.table([(0, 8, 0), (1, 4, None), (2, 4, None)])
        fb.patch(m[2], rt)
        nodes = fb.structs(bytes(16), 1)
        fb.patch(r[1], nodes)
        bufs = fb.structs(bytes(32), 2)
        fb.patch(r[2], bufs)
        meta = len(fb.b)
        while (8 + meta) % ALIGN:
            meta += 1
        self.prefix = bytes(struct.pack("<Ii", 0xFFFFFFFF, meta) + fb.b + bytes(meta - len(fb.b)))
        self.head = len(self.prefix)
        # positions (from the message start) of the numbers each batch sets
        self.at_body_len = 8 + m[3]
        self.at_length = 8 + r[0]
        self.at_node = 8 + nodes + 4
        self.at_bufs = 8 + bufs + 4

    @staticmethod
    def layout(n, width):
        """(validity offset, values offset, body length) in the body."""
        vbytes = (n + 7) // 8
        voff = (vbytes + ALIGN - 1) // ALIGN * ALIGN
        dbytes = n * width
        return 0, voff, voff + (dbytes + ALIGN - 1) // ALIGN * ALIGN

    def write(self, dst, at, n, width, nulls):
        """Writes the prefix and metadata at `dst[at:]` for a column of `n`
        rows whose body (BatchWriter.layout) the caller fills at
        dst[at + head:]. Returns the message's total size."""
        _, voff, body = self.layout(n, width)
        dst[at : at + self.head] = self.prefix
        struct.pack_into("<q", dst, at + self.at_body_len, body)
        struct.pack_into("<q", dst, at + self.at_length, n)
        struct.pack_into("<qq", dst, at + self.at_node, n, nulls)
        struct.pack_into("<qqqq", dst, at + self.at_bufs, 0, (n + 7) // 8 if nulls else 0, voff, n * width)
        return self.head + body
