# =============================================================================
# komira_async.stream.stream — Stream[T] trait + adapters
# =============================================================================
# Async iterator protocol + adapter
# combinators (iter_channel / map / filter / take / collect).
#
# This form ships the synchronous-Optional[T] form. A later step will
# lift to `IoOp[Optional[T], NoopSink, never_origin]` once reactor.run_once
# is wired (matches AsyncMutex.lock pattern in synchronous-park
# in 1.17, IoOp form in a later step).
#
# Pointer discipline:
#   - ZERO UnsafePointer in any public method signature.
#   - ZERO ArcPointer in any field — adapters are pure value-typed structs.
#   - ZERO wildcard origins on the public surface.
#   - The base `Stream` trait is a parameterless marker per Mojo 0.26.3
#     `trait Stream[T]` rejection; concrete adapters
#     declare T as a struct parameter.
#
# Design choices:
#   - `next() -> Optional[T]` (NOT IoOp form): synchronous-park.
#     Mojo 0.26.3 may not support `impl
#     Stream` returns from generic functions, so streams are
#     concrete adapter struct types".
#   - MapStream parameter order is `[S, T, U]` — forward-
#     referencing parameter S references T in its trait bound, must
#     appear FIRST.
#   - `fn(T) -> U` non-raising — Mojo 0.26.3 `fn(T) raises -> U`
#     as a struct field type is uncertain to elaborate. This may lift
#     later.
#   - ChannelStream consumes its MpscReceiver (var-take, not borrow) —
#     single-consumer enforcement at type level.
#
# Self.T / Self.U / Self.S qualifications mandatory in field decls AND
# method bodies.
# =============================================================================

from komira_async.channel.mpsc import MpscReceiver
from komira_async.channel.spsc import (
    TRY_RECV_OK,
    TRY_RECV_EMPTY,
    TRY_RECV_CLOSED,
    TryRecvOutcome,
)


# =============================================================================
# Stream — base marker trait (parameterless on Mojo 0.26.3)
# =============================================================================
# A natural shape would be `trait Stream[T]`; Mojo
# 0.26.3 rejects `trait Stream[T]` with "TODO: trait declarations do not
# support parameters yet". The fallback is a parameterless
# marker; concrete adapters carry T as a struct parameter.
#
# Adapters all conform to `Stream` so a generic free function (e.g.,
# `collect[S: Stream]`) can take any adapter as input.


trait Stream(Movable, Deinitable):
    """Async iterator trait with
    associated-type alias `T` (the same shape as
    the engine's MorselSink and
    SpawnableTask in `spawner.mojo`).

    Mojo 0.26.3 cannot declare `trait Stream[T]`; the canonical workaround
    is a trait-level associated comptime type. Conformers bind T to their
    element type:

      struct ChannelStream[U: ...](Stream, ...):
          comptime T = U
          def next(mut self) raises -> Optional[Self.T]: ...
          def close(mut self): ...

    Free functions like `collect[S: Stream, ...]` then access the
    element type via `S.T`.
    """

    comptime T: Copyable & ImplicitlyCopyable & Movable & Deinitable

    def next(mut self) raises -> Optional[Self.T]:
        ...

    def close(mut self):
        ...


# =============================================================================
# ChannelStream[T] — adapt an MpscReceiver into a Stream
# =============================================================================
#
#
# Consumes the MpscReceiver (`var recv` in iter_channel factory). Single-
# consumer enforced at type level — caller must surrender the receiver.
# next() polls try_recv until OK / CLOSED; EMPTY without close means the
# stream is still live (caller would normally park here in the IoOp form,
# but this synchronously busy-waits with a yield since there is no
# reactor surface to park on).
#


struct ChannelStream[
    U: Copyable & ImplicitlyCopyable & Movable & Deinitable
](Stream, Movable, Deinitable):
    """Adapt an MpscReceiver into a
    Stream. End-of-stream when the upstream sender has closed AND the
    queue is drained.

    21 synchronous form: next() returns:
      - Some(value) if try_recv yields TRY_RECV_OK
      - None if try_recv yields TRY_RECV_CLOSED (sender dropped + drained)
      - Some/None loop on TRY_RECV_EMPTY — this currently treats
        EMPTY-but-open as a busy-wait+yield until a value arrives or the
        sender closes. A reactor-driven park would replace this.
    """

    comptime T = Self.U

    var _recv: MpscReceiver[Self.T]
    var _closed: Bool

    def __init__(out self, var recv: MpscReceiver[Self.T]):
        self._recv = recv^
        self._closed = False

    def next(mut self) raises -> Optional[Self.T]:
        """Pull the next item. Returns None when the upstream is drained
        AND closed."""
        if self._closed:
            return Optional[Self.T]()
        # Loop on EMPTY — busy-wait. In the unit tests
        # we always close BEFORE iterating, so the sender_closed branch
        # fires on the first empty observation; multi-thread tests are
        # deferred.
        while True:
            var outcome = self._recv.try_recv()
            if outcome.status == TRY_RECV_OK:
                return Optional[Self.T](outcome.value())
            if outcome.status == TRY_RECV_CLOSED:
                self._closed = True
                return Optional[Self.T]()
            # TRY_RECV_EMPTY (sender still alive). The unit tests
            # always close upstream first, so this branch is exercised
            # only when a producer races with a consumer mid-test — not
            # the case here. Fall through to the next iteration; in a
            # contended-test scenario this becomes a busy-wait. a later step
            # parks via wake_primitives.
            continue

    def close(mut self):
        """Mark this stream closed; subsequent next() returns None."""
        self._closed = True
        self._recv.close()


# =============================================================================
# MapStream[S, T, U] — apply f: T -> U to each element of an inner Stream
# =============================================================================
# Parameter order is [S, T, U]: a forward-referencing parameter S, which
# references T in its trait bound, must appear FIRST.


struct MapStream[
    S: Stream,
    OutT: Copyable & ImplicitlyCopyable & Movable & Deinitable,
](Stream, Movable, Deinitable):
    """MapStream applies
    `_f: fn(S.T) -> OutT` to each element of an inner Stream, yielding
    OutT.

    21 limitations:
    1. `_f` is a non-raising fn pointer. Mojo 0.26.3 rejects
       `fn(T) raises -> U` as a struct field; v0.2 may lift this once
       raise-fn-as-field elaborates.
    2. Parameter shape [S, OutT] (NOT [S, InT, OutT]) — Mojo 0.26.3
       cannot express `S.T == InT` as a constraint. We use the trait's
       associated-type alias `S.T` directly as the input type, so the
       caller spells out `MapStream[ChannelStream[Int], Int]` (output
       type only).
    """

    comptime T = Self.OutT

    var _inner: Self.S
    var _f: def (Self.S.T) thin -> Self.OutT
    var _exhausted: Bool

    def __init__(
        out self,
        var _inner: Self.S,
        _f: def (Self.S.T) thin -> Self.OutT,
    ):
        self._inner = _inner^
        self._f = _f
        self._exhausted = False

    def next(mut self) raises -> Optional[Self.T]:
        """Pull next from inner; if Some(t), return Some(_f(t)); else None."""
        if self._exhausted:
            return Optional[Self.T]()
        var inner_item = self._inner.next()
        if not inner_item.__bool__():
            self._exhausted = True
            return Optional[Self.T]()
        var inner_value = inner_item.value()
        var mapped = self._f(inner_value)
        return Optional[Self.T](mapped)

    def close(mut self):
        self._exhausted = True
        self._inner.close()


# =============================================================================
# FilterStream[S, T] — keep only elements for which pred(t) is True
# =============================================================================
#


struct FilterStream[S: Stream](Stream, Movable, Deinitable):
    """FilterStream applies a
    predicate `_pred: fn(S.T) -> Bool` to each inner element; yields
    only those for which the predicate returns True.

    Parameter shape [S] only — element type comes from S's associated-
    type alias `S.T`. `alias T = Self.S.T` so collect[FilterStream[...]]
    resolves cleanly via the Stream trait.
    """

    comptime T = Self.S.T

    var _inner: Self.S
    var _pred: def (Self.T) thin -> Bool
    var _exhausted: Bool

    def __init__(
        out self,
        var _inner: Self.S,
        _pred: def (Self.T) thin -> Bool,
    ):
        self._inner = _inner^
        self._pred = _pred
        self._exhausted = False

    def next(mut self) raises -> Optional[Self.T]:
        """Pull next from inner until pred(t) is True or inner exhausted."""
        if self._exhausted:
            return Optional[Self.T]()
        while True:
            var inner_item = self._inner.next()
            if not inner_item.__bool__():
                self._exhausted = True
                return Optional[Self.T]()
            var inner_value = inner_item.value()
            if self._pred(inner_value):
                return Optional[Self.T](inner_value)
            # Predicate rejected; continue with next element.

    def close(mut self):
        self._exhausted = True
        self._inner.close()


# =============================================================================
# TakeStream[S, T] — yield at most N items from an inner Stream
# =============================================================================
#


struct TakeStream[S: Stream](Stream, Movable, Deinitable):
    """TakeStream caps the inner
    stream to at most N elements. Decrements `_remaining` each yielded
    item; returns None once `_remaining == 0` OR inner exhausts.

    Note: TakeStream does NOT close the inner stream on cap-reached —
    callers may want to keep pulling from the same channel via a fresh
    stream. close() is explicit + forwards.

    Parameter shape [S] only — element type comes from S.T.
    """

    comptime T = Self.S.T

    var _inner: Self.S
    var _remaining: UInt

    def __init__(
        out self,
        var _inner: Self.S,
        _remaining: UInt,
    ):
        self._inner = _inner^
        self._remaining = _remaining

    def next(mut self) raises -> Optional[Self.T]:
        if self._remaining == UInt(0):
            return Optional[Self.T]()
        var inner_item = self._inner.next()
        if not inner_item.__bool__():
            self._remaining = UInt(0)
            return Optional[Self.T]()
        self._remaining = self._remaining - UInt(1)
        return Optional[Self.T](inner_item.value())

    def close(mut self):
        self._remaining = UInt(0)
        self._inner.close()


# =============================================================================
# Free functions: iter_channel, collect
# =============================================================================
#


def iter_channel[
    T: Copyable & ImplicitlyCopyable & Movable & Deinitable
](var recv: MpscReceiver[T]) -> ChannelStream[T]:
    """Wrap a single-consumer MpscReceiver
    as a Stream. Consumes the receiver (single-consumer enforcement).

    The returned ChannelStream owns the receiver; closing the stream
    closes the receiver."""
    return ChannelStream[T](recv=recv^)


def collect[S: Stream](var stream: S) raises -> List[S.T]:
    """Drain a stream into a List. Calls
    .next() repeatedly until None; appends each Some(t) to the result.

    Uses the Stream trait's associated-type alias `T`
    so the caller doesn't need to spell out the element
    type — `collect[ChannelStream[Int]](s)` returns `List[Int]`."""
    var result = List[S.T]()
    while True:
        var item = stream.next()
        if not item.__bool__():
            break
        result.append(item.value())
    return result^
