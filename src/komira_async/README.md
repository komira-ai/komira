# komira_async

komira's async substrate: per-core workers, each owning an I/O reactor
(epoll on Linux, kqueue on macOS), a fork-join dispatcher, and the pieces
async code is built from, in one package:

- `channel`: bounded MPSC (Vyukov ring, power-of-two capacity), SPSC,
  oneshot and broadcast channels. For MPSC, SPSC and oneshot, `try_send`
  returns a status (`TRY_SEND_OK`, `TRY_SEND_FULL`, `TRY_SEND_CLOSED`;
  oneshot's `send` returns `SEND_OK` or `SEND_CLOSED`) instead of
  blocking, `try_recv` an outcome (`TRY_RECV_OK`, `TRY_RECV_EMPTY`,
  `TRY_RECV_CLOSED`), and a value is moved, never copied. Broadcast is
  different: `T` must be `Copyable & ImplicitlyCopyable`, every subscriber
  receives its own copy, and `send` never fails (it returns the live
  subscriber count) because it overwrites the oldest slot of a full ring.
  A subscriber's `try_recv` returns a `BroadcastRecvOutcome` whose status is
  `BCAST_RECV_OK`, `BCAST_RECV_EMPTY`, `BCAST_RECV_CLOSED` or
  `BCAST_RECV_LAGGED`; LAGGED means the subscriber fell more than a ring's
  capacity behind and lost values, and its cursor jumps to the oldest value
  still held.
- `cancellation`: `CancellationToken` (re-exported from
  `komira_async_api.token`, where it is defined; both import paths name the
  same type), a tree of tokens where cancelling a parent cancels every child
  (never the reverse); a token cancelled twice keeps its first reason, and a
  token reports the reason of the outermost cancelled token on its chain;
  `ExecutionBudget`.
- `sync`: `AsyncMutex`, `AsyncRwLock`, `Semaphore`, `Notify`.
- `reactor`, `ops` (`IoOp`, the `WakerSink` trait), `timer` (a hierarchical
  timer wheel), `spawner` (fork-join spawning, join handles, task scopes),
  `stream` (a `Stream[T]` trait and adapters), `morsel` (`MorselPool`) and
  `runtime` (`PerCoreAsyncRuntime`, `Worker`).
- `errors`: `IoError`, `AsyncError`, `CancelledError`, `TimeoutError`,
  `ChannelClosed`.

There is no facade: import from the sub-modules
(`komira_async.channel.mpsc`, `komira_async.cancellation.token`, and so on).
Closing one clone of an MPSC sender closes the channel for the receiver;
there is no close-on-last-drop.

## Examples

A bounded MPSC channel with two producers:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_async.channel.mpsc import channel as mpsc_channel
from komira_async.channel.spsc import TRY_RECV_CLOSED, TRY_RECV_EMPTY, TRY_RECV_OK
from komira_async.channel.spsc import TRY_SEND_FULL, TRY_SEND_OK

var pair = mpsc_channel[String](capacity=UInt(2))
var tx_a = pair.take_sender()
var tx_b = tx_a.clone()
var rx = pair.take_receiver()

assert_equal(tx_a.try_send("from a"), TRY_SEND_OK)
assert_equal(tx_b.try_send("from b"), TRY_SEND_OK)
assert_equal(tx_a.try_send("one too many"), TRY_SEND_FULL)  # never blocks

var first = rx.try_recv()
assert_equal(first.status, TRY_RECV_OK)
assert_equal(first.take_value(), "from a")
var second = rx.try_recv()
assert_equal(second.take_value(), "from b")
assert_equal(rx.try_recv().status, TRY_RECV_EMPTY)

tx_a.close()
assert_equal(rx.try_recv().status, TRY_RECV_CLOSED)
```

A capacity that is not a power of two is refused:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_async.channel.mpsc import channel as mpsc_channel

var message = String()
try:
    _ = mpsc_channel[Int](capacity=UInt(3))
except e:
    message = String(e)
assert_equal(message, "MpscChannel: capacity must be a power of 2")
```

A oneshot channel carries one value:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_async.channel.oneshot import SEND_OK, channel as oneshot_channel
from komira_async.channel.spsc import TRY_RECV_OK

var pair = oneshot_channel[Int]()
var tx = pair.take_sender()
var rx = pair.take_receiver()
assert_equal(tx^.send(55), SEND_OK)  # `send` consumes the sender
var got = rx.try_recv()
assert_equal(got.status, TRY_RECV_OK)
assert_equal(got.value(), 55)
```

Cancellation flows down a token tree, never up; the outermost reason is the
one every descendant reports:

<!-- mojo-hidden from std.testing import assert_equal, assert_true, assert_false -->
```mojo
from komira_async.cancellation.token import CancellationToken

var query = CancellationToken.new()
var scan = query.child()
var other = query.child()

other.cancel("limit reached")
assert_true(other.is_cancelled())
assert_false(query.is_cancelled())  # a child does not cancel its parent
assert_equal(other.reason(), "limit reached")

query.cancel("client went away")
query.cancel("second reason")
assert_true(scan.is_cancelled())
assert_equal(scan.reason(), "client went away")
assert_equal(other.reason(), "client went away")  # the outermost reason
```
