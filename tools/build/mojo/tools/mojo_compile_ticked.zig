//! mojo_compile_ticked: the compile wrapper (mojo_compile.zig) with its
//! watchdog's ticks supplied by the process that runs it, for the process
//! cases (tests//functional/watchdog:cases) only. It is the same program:
//! the one declaration below is what watch_loop.zig reads to take a tick from
//! descriptor 3 (and to acknowledge it on descriptor 4) in place of a
//! one-second sleep.

const wrapper = @import("mojo_compile.zig");

pub const tick_source: enum { inherited_fd } = .inherited_fd;

pub const main = wrapper.main;
