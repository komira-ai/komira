//! mojo_compile_macos_ticked: the macOS compile wrapper (mojo_compile_macos.zig)
//! with its watchdog's ticks supplied by the process that runs it, for the
//! process cases (tests//functional/watchdog:cases_darwin) only; see
//! mojo_compile_ticked.zig.

const wrapper = @import("mojo_compile_macos.zig");

pub const tick_source: enum { inherited_fd } = .inherited_fd;

pub const main = wrapper.main;
