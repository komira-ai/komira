//! The action-category variable reaches the process a heavy action runs
//! (action_category.bzl). A `zig_test` is one of the heavy actions, so this
//! test runs with the variable `run_heavy` set, and reads it back under the
//! name the remote-execution service reads (komira-ai/komira-build-farm),
//! written here and not taken from the .bzl: a misspelt or renamed variable,
//! a value that is not the category, or `zig_test` no longer run through
//! `run_heavy` is red here.

const std = @import("std");

test "a zig_test action carries KBF_ACTION_CATEGORY=zig_test" {
    const got = std.posix.getenv("KBF_ACTION_CATEGORY") orelse {
        std.debug.print("KBF_ACTION_CATEGORY is not set in the zig_test action\n", .{});
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqualStrings("zig_test", got);
}
