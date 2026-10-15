//! A stand-in for git and git-lfs, by the name it is run as, for git_check's
//! cases: `git` answers the commands git_check asks, as git does, from a mode
//! file `../MODE` (next to bin/) that says which one to get wrong; `git-lfs`
//! prints its version line. Object ids are computed as git computes them.
//!
//! Modes: ok, version, execpath, hash, tree, commit, env (the identities are
//! not in the environment), clone, push, ls_ok (ls-remote to the closed port
//! succeeds), ls_text, https_text, lfs_via_git (`git lfs version` differs),
//! decoy (git runs a git-upload-pack from PATH).
const std = @import("std");

fn objectId(kind: []const u8, content: []const u8) [40]u8 {
    var h = std.crypto.hash.Sha1.init(.{});
    var head: [64]u8 = undefined;
    h.update(std.fmt.bufPrint(&head, "{s} {d}\x00", .{ kind, content.len }) catch unreachable);
    h.update(content);
    var d: [20]u8 = undefined;
    h.final(&d);
    return std.fmt.bytesToHex(d, .lower);
}

fn is(mode: []const u8, want: []const u8) bool {
    return std.mem.eql(u8, mode, want);
}

fn writeFile(path: []const u8, data: []const u8) !void {
    const f = try std.fs.cwd().createFile(path, .{});
    defer f.close();
    try f.writeAll(data);
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const args = try std.process.argsAlloc(a);
    const out = std.io.getStdOut().writer();
    const base = std.fs.path.basename(args[0]);
    if (std.mem.eql(u8, base, "git-lfs")) {
        try out.writeAll("git-lfs/3.8.0 (GitHub; linux amd64; go 1.25.0)\n");
        return;
    }
    const dir = std.fs.path.dirname(args[0]) orelse ".";
    const dist = try std.fs.path.join(a, &.{ dir, ".." });
    const mode_text = std.fs.cwd().readFileAlloc(a, try std.fs.path.join(a, &.{ dist, "MODE" }), 100) catch "ok";
    const mode = std.mem.trim(u8, mode_text, " \n");

    var i: usize = 1;
    var cdir: []const u8 = ".";
    if (args.len > 2 and std.mem.eql(u8, args[1], "-C")) {
        cdir = args[2];
        i = 3;
    }
    const cmd = if (i < args.len) args[i] else "";
    const rest = if (i + 1 <= args.len) args[i + 1 ..] else args[0..0];

    if (std.mem.eql(u8, cmd, "--version")) {
        try out.print("git version {s}\n", .{if (is(mode, "version")) "9.9.9" else "2.56.0"});
    } else if (std.mem.eql(u8, cmd, "--exec-path")) {
        const p = if (is(mode, "execpath")) "/tmp" else try std.fs.path.join(a, &.{ dist, "libexec/git-core" });
        try out.print("{s}\n", .{p});
    } else if (std.mem.eql(u8, cmd, "init")) {
        const target = rest[rest.len - 1];
        try std.fs.cwd().makePath(target);
    } else if (std.mem.eql(u8, cmd, "hash-object")) {
        const data = try std.fs.cwd().readFileAlloc(a, try std.fs.path.join(a, &.{ cdir, rest[1] }), 1 << 16);
        const id = objectId("blob", data);
        try out.print("{s}\n", .{if (is(mode, "hash")) "0000000000000000000000000000000000000000" else &id});
    } else if (std.mem.eql(u8, cmd, "mktree")) {
        const id = objectId("tree", "");
        try out.print("{s}\n", .{if (is(mode, "tree")) "1111111111111111111111111111111111111111" else &id});
    } else if (std.mem.eql(u8, cmd, "commit-tree")) {
        const tree = rest[rest.len - 1];
        if (!is(mode, "env")) {
            const need = [_][2][]const u8{
                .{ "GIT_AUTHOR_NAME", "A U Thor" },
                .{ "GIT_AUTHOR_EMAIL", "author@example.com" },
                .{ "GIT_AUTHOR_DATE", "1790000000 +0000" },
                .{ "GIT_COMMITTER_NAME", "C O Mitter" },
                .{ "GIT_COMMITTER_EMAIL", "committer@example.com" },
                .{ "GIT_COMMITTER_DATE", "1790000000 +0000" },
            };
            for (need) |kv| {
                const got = std.process.getEnvVarOwned(a, kv[0]) catch "";
                if (!std.mem.eql(u8, got, kv[1])) std.process.exit(1);
            }
        } else std.process.exit(1);
        const body = try std.fmt.allocPrint(a, "tree {s}\nauthor A U Thor <author@example.com> 1790000000 +0000\ncommitter C O Mitter <committer@example.com> 1790000000 +0000\n\nsmoke\n", .{tree});
        const id = objectId("commit", body);
        try out.print("{s}\n", .{if (is(mode, "commit")) "2222222222222222222222222222222222222222" else &id});
    } else if (std.mem.eql(u8, cmd, "update-ref")) {
        try writeFile(try std.fs.path.join(a, &.{ cdir, "MAIN" }), rest[1]);
    } else if (std.mem.eql(u8, cmd, "clone")) {
        if (is(mode, "clone")) std.process.exit(128);
        const url = rest[rest.len - 2];
        const target = rest[rest.len - 1];
        const src = url["file://".len..];
        const main_id = try std.fs.cwd().readFileAlloc(a, try std.fs.path.join(a, &.{ src, "MAIN" }), 100);
        try std.fs.cwd().makePath(target);
        try writeFile(try std.fs.path.join(a, &.{ target, "MAIN" }), main_id);
    } else if (std.mem.eql(u8, cmd, "rev-parse")) {
        const id = try std.fs.cwd().readFileAlloc(a, try std.fs.path.join(a, &.{ cdir, "MAIN" }), 100);
        try out.print("{s}\n", .{id});
    } else if (std.mem.eql(u8, cmd, "fsck")) {
        // nothing to find
    } else if (std.mem.eql(u8, cmd, "push")) {
        if (is(mode, "push")) std.process.exit(1);
        const url = rest[rest.len - 2];
        const target = url["file://".len..];
        const id = try std.fs.cwd().readFileAlloc(a, try std.fs.path.join(a, &.{ cdir, "MAIN" }), 100);
        try writeFile(try std.fs.path.join(a, &.{ target, "MAIN" }), id);
    } else if (std.mem.eql(u8, cmd, "ls-remote")) {
        const url = rest[0];
        if (std.mem.startsWith(u8, url, "http://")) {
            if (is(mode, "ls_ok")) return;
            const wait: []const u8 = if (is(mode, "ls_text")) "Connection refused" else "Could not connect to server";
            std.debug.print("fatal: unable to access 'http://127.0.0.1:1/r/': Failed to connect to 127.0.0.1:1 after 3 ms: {s}\n", .{wait});
            std.process.exit(128);
        }
        const what: []const u8 = if (is(mode, "https_text")) "is not allowed" else "is disabled";
        std.debug.print("fatal: unable to access 'https://127.0.0.1:1/r/': Protocol \"https\" {s}\n", .{what});
        std.process.exit(128);
    } else if (std.mem.eql(u8, cmd, "lfs")) {
        const r = try std.process.Child.run(.{ .allocator = a, .argv = &.{ "git-lfs", "version" } });
        if (is(mode, "lfs_via_git")) {
            try out.writeAll("git-lfs/3.8.0 (something else)\n");
        } else try out.writeAll(r.stdout);
    } else {
        std.debug.print("fake git: {s}\n", .{cmd});
        std.process.exit(129);
    }
    if (is(mode, "decoy") and std.mem.eql(u8, cmd, "--version")) {
        _ = std.process.Child.run(.{ .allocator = a, .argv = &.{ "git-upload-pack", "--stateless-rpc" } }) catch {};
    }
}
