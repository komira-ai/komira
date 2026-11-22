"""Framing and message codecs of the private wire between the runtime library, the
zygote and its workers (wire version 3, little-endian).

Pure standard library: this module imports no pyarrow and no other komira module.
"""

import array
import os
import socket
import struct
from typing import Iterable, NamedTuple, Optional, Tuple

WIRE_VERSION = 3
MAGIC = 0x4644554B
HEADER = struct.Struct("<IIQIIQQ")
HEADER_SIZE = HEADER.size  # 40
HEAD = struct.Struct("<QqqII32x")
HEAD_SIZE = HEAD.size  # 64
MAX_PAYLOAD = 1 << 31

OP_HELLO = 1
OP_LOAD = 4
OP_UNLOAD = 5
OP_OPEN_INSTANCE = 8
OP_CLOSE_INSTANCE = 9
OP_CALL_BATCH = 10
OP_SHUTDOWN = 22
OP_FORK = 30
OP_OK = 128
OP_ERROR = 129
OP_EXIT = 130

FLAG_INLINE = 1
FLAG_RETIRE = 4
FLAG_RETRY = 8

ERR_ABI = 1
ERR_DESCRIPTOR = 2
ERR_UNSUPPORTED = 3
ERR_CODE_DIGEST = 4
ERR_LOAD = 5
ERR_RAISED = 6
ERR_RETURN_TYPE = 7
ERR_LENGTH = 8
ERR_CANCELLED = 11
ERR_DEADLINE = 12
ERR_OUT_OF_MEMORY = 13
ERR_INTERNAL = 15

FORM_PACKAGE = 1
FORM_BUNDLE = 2

SHAPE_SCALAR = 1 << 0
SHAPE_MAP_BATCHES_COLUMN = 1 << 2

FORMAT_VALUES = 1
FORMAT_ARROW = 2

_ANCILLARY_SPACE = socket.CMSG_SPACE(16 * struct.calcsize("i"))


class WireError(Exception):
    """The peer's bytes break the framing."""


class Message(NamedTuple):
    op: int
    request_id: int
    flags: int
    payload: bytes
    fds: list


def pack_str(text: str) -> bytes:
    raw = text.encode("utf-8")
    return struct.pack("<I", len(raw)) + raw


def read_str(buf, off: int) -> Tuple[str, int]:
    """Read a u32-length-prefixed UTF-8 string at `off`; return it and the next offset."""
    if off + 4 > len(buf):
        raise WireError("string length truncated at byte %d" % off)
    (n,) = struct.unpack_from("<I", buf, off)
    off += 4
    if off + n > len(buf):
        raise WireError("string of %d bytes truncated at byte %d" % (n, off))
    try:
        text = bytes(buf[off : off + n]).decode("utf-8")
    except UnicodeDecodeError as e:
        raise WireError("string at byte %d is not UTF-8: %s" % (off, e)) from None
    return text, off + n


def pack_head(handle: int, deadline_ns_left: int = 0, call_id: int = 0) -> bytes:
    return HEAD.pack(handle, deadline_ns_left, call_id, 0, 0)


def split_request(payload) -> Tuple[int, int, int, memoryview]:
    """Split a request payload into (handle, deadline_ns_left, call_id, body)."""
    if len(payload) < HEAD_SIZE:
        raise WireError("request payload of %d bytes is shorter than the 64-byte head" % len(payload))
    handle, deadline, call_id, _, _ = HEAD.unpack_from(payload, 0)
    return handle, deadline, call_id, memoryview(payload)[HEAD_SIZE:]


def pack_error(code: int, message: str, row: int = -1, group: int = -1, trace: str = "") -> bytes:
    return struct.pack("<iqq", code, row, group) + pack_str(message) + pack_str(trace)


def unpack_error(body) -> Tuple[int, int, int, str, str]:
    if len(body) < 20:
        raise WireError("ERROR body of %d bytes is too short" % len(body))
    code, row, group = struct.unpack_from("<iqq", body, 0)
    message, off = read_str(body, 20)
    trace, _ = read_str(body, off)
    return code, row, group, message, trace


def _take_fds(ancillary, fds: list) -> None:
    for level, kind, data in ancillary:
        if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
            arr = array.array("i")
            arr.frombytes(bytes(data[: len(data) - (len(data) % arr.itemsize)]))
            fds.extend(arr)


def _recv_into(sock: socket.socket, view: memoryview, fds: list) -> int:
    """Fill `view` from `sock`; return the bytes read (short only at end of stream)."""
    got = 0
    flags = getattr(socket, "MSG_CMSG_CLOEXEC", 0)
    while got < len(view):
        try:
            n, ancillary, _, _ = sock.recvmsg_into([view[got:]], _ANCILLARY_SPACE, flags)
        except ConnectionResetError:
            return got
        _take_fds(ancillary, fds)
        if n == 0:
            break
        got += n
    return got


def recv_message(sock: socket.socket) -> Optional[Message]:
    """Read one whole message. Returns None at end of stream before any byte of a message;
    raises WireError for end of stream inside a message, a bad magic or an oversize payload.
    Descriptors that arrived with the message are in `fds` (close-on-exec)."""
    fds: list = []
    head = bytearray(HEADER_SIZE)
    got = _recv_into(sock, memoryview(head), fds)
    if got == 0:
        _close_all(fds)
        return None
    try:
        if got < HEADER_SIZE:
            raise WireError("end of stream after %d of %d header bytes" % (got, HEADER_SIZE))
        magic, op, request_id, flags, _slot, _off, length = HEADER.unpack(head)
        if magic != MAGIC:
            raise WireError("bad magic 0x%08x" % magic)
        if length > MAX_PAYLOAD:
            raise WireError("payload of %d bytes exceeds the maximum" % length)
        payload = bytearray(length)
        if length:
            n = _recv_into(sock, memoryview(payload), fds)
            if n < length:
                raise WireError("end of stream after %d of %d payload bytes" % (n, length))
    except WireError:
        _close_all(fds)
        raise
    return Message(op, request_id, flags, bytes(payload), fds)


def _close_all(fds: Iterable[int]) -> None:
    for fd in fds:
        try:
            os.close(fd)
        except OSError:
            pass


def send_message(
    sock: socket.socket,
    op: int,
    request_id: int,
    payload: bytes = b"",
    flags: int = 0,
    fds: Iterable[int] = (),
) -> None:
    """Send one message in a single `sendmsg` when descriptors ride along."""
    if payload:
        flags |= FLAG_INLINE
    data = HEADER.pack(MAGIC, op, request_id, flags, 0, 0, len(payload)) + bytes(payload)
    fds = list(fds)
    if not fds:
        sock.sendall(data)
        return
    sent = sock.sendmsg([data], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", fds))])
    if sent < len(data):
        sock.sendall(memoryview(data)[sent:])


def send_ok(sock: socket.socket, request_id: int, body: bytes = b"", flags: int = 0) -> None:
    send_message(sock, OP_OK, request_id, body, flags)


def send_error(
    sock: socket.socket,
    request_id: int,
    code: int,
    message: str,
    row: int = -1,
    group: int = -1,
    trace: str = "",
    flags: int = 0,
) -> None:
    send_message(sock, OP_ERROR, request_id, pack_error(code, message, row, group, trace), flags)
