//! debug_relocate: overwrite a directory path inside a file with a
//! placeholder of the same length.
//!
//! usage: debug_relocate <file> <dir>...
//!
//! For each <dir> in order (absolute, no trailing '/', at least 8 bytes long),
//! every occurrence of its bytes in <file> that is followed by '/' or NUL
//! becomes '/' followed by '_' repeated to the same length, so
//! "/worker/build/0123456789abcdef/root" (35 bytes) becomes "/" and 34 '_'.
//! Occurrences are found left to right and do not overlap; the byte before
//! one is not looked at. The file never changes length, so no offset in it
//! moves.
//!
//! An occurrence followed by any other byte, or by the end of the file, is
//! refused: it is a longer name that only starts with <dir>
//! ("/root2"), and rewriting it would make a path that names nothing it named
//! before. The file is then left untouched.
//!
//! The placeholder is a path that does not exist on any machine this runs
//! on, which is the point: a tool that resolves the path with realpath before
//! rewriting it (kcov does) leaves it as written, and a regular expression
//! (`^/_+`) then finds it. See README.md.
//!
//! The file is rewritten through a temporary file in its directory, renamed
//! over it, with the original permission bits; the temporary file is removed
//! if a step fails. A symbolic link is refused (the rename would replace the
//! link, not the file it names). A file with no occurrence of any <dir> is not
//! written at all.
//!
//! An ELF file with a section whose flags hold SHF_COMPRESSED is refused,
//! and so is one whose section headers cannot be read (not little-endian, or
//! past the end of the file): a compressed section's bytes are not the
//! strings it holds, so a byte search could miss <dir> there and the counts
//! would claim a clean file. Any other file is searched as bytes.
//!
//! Prints one line per <dir>, `<count> <dir>`, before the file is written.
//!
//! Exit status: 0 done; 1 an occurrence followed by another byte, a
//! compressed or unreadable ELF file, a symbolic link, or an I/O error,
//! stdout included (the file is unchanged in every case); 2 bad usage.
//!
//! An I/O error is named as the Zig 0.12 standard library names the errno of
//! that call (`FileNotFound`, `FileTooBig`, ...), the names this tool printed
//! when it was written in Zig, so its messages did not change with the
//! rewrite.
//!
//! A Rust executable linked against glibc (2.34 or newer, tools/build/rust/
//! README.md); it runs with no shell, no PATH and no network.

use std::collections::hash_map::RandomState;
use std::ffi::OsString;
use std::fs::{self, File, OpenOptions};
use std::hash::{BuildHasher, Hasher};
use std::io::{self, Write};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process;

const USAGE: &str = "usage: debug_relocate <file> <dir>...\n  each <dir> absolute, without a trailing '/', at least 8 bytes long\n";

const MIN_DIR_LEN: usize = 8;
const MAX_FILE: u64 = 1 << 34;
const SHF_COMPRESSED: u64 = 0x800;

/// Writes `debug_relocate: <msg>\n` (and the usage text for exit 2) to
/// stderr and exits. Errors writing stderr are ignored, as Zig's
/// `std.debug.print` ignores them.
fn exit_with(msg: &[u8], code: i32) -> ! {
    let mut line = b"debug_relocate: ".to_vec();
    line.extend_from_slice(msg);
    line.push(b'\n');
    if code == 2 {
        line.extend_from_slice(USAGE.as_bytes());
    }
    let _ = io::stderr().lock().write_all(&line);
    process::exit(code);
}

fn fail(msg: &[u8]) -> ! {
    exit_with(msg, 1)
}

fn usage_fail(msg: &[u8]) -> ! {
    exit_with(msg, 2)
}

/// `parts` joined: byte strings (paths, directories) and text.
fn cat(parts: &[&[u8]]) -> Vec<u8> {
    parts.concat()
}

/// The system call an errno came from: Zig 0.12 names the same errno
/// differently per call.
#[derive(Clone, Copy)]
enum Call {
    Readlink,
    Stat,
    Open,
    Read,
    Write,
    Chmod,
    Rename,
}

/// The Zig 0.12 error name of `err` returned by `call`.
fn zig_name(call: Call, err: &io::Error) -> &'static str {
    let Some(e) = err.raw_os_error() else {
        return "Unexpected";
    };
    // Linux x86_64 errno values.
    const EPERM: i32 = 1;
    const ENOENT: i32 = 2;
    const EIO: i32 = 5;
    const ENXIO: i32 = 6;
    const EBADF: i32 = 9;
    const EAGAIN: i32 = 11;
    const ENOMEM: i32 = 12;
    const EACCES: i32 = 13;
    const EBUSY: i32 = 16;
    const EEXIST: i32 = 17;
    const EXDEV: i32 = 18;
    const ENODEV: i32 = 19;
    const ENOTDIR: i32 = 20;
    const EISDIR: i32 = 21;
    const EINVAL: i32 = 22;
    const ENFILE: i32 = 23;
    const EMFILE: i32 = 24;
    const ETXTBSY: i32 = 26;
    const EFBIG: i32 = 27;
    const ENOSPC: i32 = 28;
    const EROFS: i32 = 30;
    const EMLINK: i32 = 31;
    const EPIPE: i32 = 32;
    const ENAMETOOLONG: i32 = 36;
    const ENOTEMPTY: i32 = 39;
    const ELOOP: i32 = 40;
    const EOVERFLOW: i32 = 75;
    const ECONNRESET: i32 = 104;
    const ENOBUFS: i32 = 105;
    const EDQUOT: i32 = 122;
    match call {
        Call::Readlink => match e {
            EACCES => "AccessDenied",
            EINVAL => "NotLink",
            EIO => "FileSystem",
            ELOOP => "SymLinkLoop",
            ENAMETOOLONG => "NameTooLong",
            ENOENT => "FileNotFound",
            ENOMEM => "SystemResources",
            ENOTDIR => "NotDir",
            _ => "Unexpected",
        },
        Call::Stat => match e {
            EACCES => "AccessDenied",
            ENOMEM => "SystemResources",
            ENOENT | ENOTDIR => "FileNotFound",
            ELOOP => "SymLinkLoop",
            ENAMETOOLONG => "NameTooLong",
            _ => "Unexpected",
        },
        Call::Open => match e {
            EACCES | EPERM => "AccessDenied",
            EFBIG | EOVERFLOW => "FileTooBig",
            EISDIR => "IsDir",
            ELOOP => "SymLinkLoop",
            EMFILE => "ProcessFdQuotaExceeded",
            ENAMETOOLONG => "NameTooLong",
            ENFILE => "SystemFdQuotaExceeded",
            ENODEV => "NoDevice",
            ENOENT => "FileNotFound",
            ENOMEM => "SystemResources",
            ENOSPC => "NoSpaceLeft",
            ENOTDIR => "NotDir",
            EEXIST => "PathAlreadyExists",
            EBUSY => "DeviceBusy",
            EAGAIN => "WouldBlock",
            ETXTBSY => "FileBusy",
            _ => "Unexpected",
        },
        Call::Read => match e {
            EAGAIN => "WouldBlock",
            EBADF => "NotOpenForReading",
            EIO => "InputOutput",
            EISDIR => "IsDir",
            ENOMEM | ENOBUFS => "SystemResources",
            ECONNRESET => "ConnectionResetByPeer",
            _ => "Unexpected",
        },
        Call::Write => match e {
            EINVAL => "InvalidArgument",
            EAGAIN => "WouldBlock",
            EBADF => "NotOpenForWriting",
            EDQUOT => "DiskQuota",
            EFBIG => "FileTooBig",
            EIO => "InputOutput",
            ENOSPC => "NoSpaceLeft",
            EPERM | EACCES => "AccessDenied",
            EPIPE => "BrokenPipe",
            ECONNRESET => "ConnectionResetByPeer",
            EBUSY => "DeviceBusy",
            ENXIO => "NoDevice",
            _ => "Unexpected",
        },
        Call::Chmod => match e {
            EPERM => "AccessDenied",
            EIO => "InputOutput",
            ELOOP => "SymLinkLoop",
            ENOENT | ENOTDIR => "FileNotFound",
            ENOMEM => "SystemResources",
            EROFS => "ReadOnlyFileSystem",
            _ => "Unexpected",
        },
        Call::Rename => match e {
            EACCES | EPERM => "AccessDenied",
            EBUSY => "FileBusy",
            EDQUOT => "DiskQuota",
            EISDIR => "IsDir",
            ELOOP => "SymLinkLoop",
            EMLINK => "LinkQuotaExceeded",
            ENAMETOOLONG => "NameTooLong",
            ENOENT => "FileNotFound",
            ENOTDIR => "NotDir",
            ENOMEM => "SystemResources",
            ENOSPC => "NoSpaceLeft",
            EEXIST | ENOTEMPTY => "PathAlreadyExists",
            EROFS => "ReadOnlyFileSystem",
            EXDEV => "RenameAcrossMountPoints",
            _ => "Unexpected",
        },
    }
}

fn le(buf: &[u8], at: u64, n: usize) -> u64 {
    let at = at as usize;
    buf[at..at + n]
        .iter()
        .rev()
        .fold(0u64, |v, &b| (v << 8) | u64::from(b))
}

/// Refuses (exit 1, nothing written) an ELF file holding a section whose
/// flags have SHF_COMPRESSED, or whose section headers cannot be read. A
/// file that does not start with the ELF magic is not looked at.
fn refuse_compressed(path: &[u8], buf: &[u8]) {
    if buf.len() < 4 || &buf[0..4] != b"\x7fELF" {
        return;
    }
    let unread = |why: &str| -> ! {
        fail(&cat(&[
            path,
            b": an ELF file whose section headers cannot be read (",
            why.as_bytes(),
            b"), so no section can be shown uncompressed; the file is left unchanged",
        ]))
    };
    let len = buf.len() as u64;
    if buf.len() < 52 {
        unread("shorter than an ELF header");
    }
    if buf[5] != 1 {
        unread("not little-endian");
    }
    // (offset of e_shoff, e_shentsize, e_shnum), and of sh_flags and sh_size
    // in a section header, by class: ELF64 or ELF32.
    let wide = match buf[4] {
        2 => true,
        1 => false,
        _ => unread("neither ELF32 nor ELF64"),
    };
    if wide && buf.len() < 64 {
        unread("shorter than an ELF64 header");
    }
    let shoff = if wide { le(buf, 0x28, 8) } else { le(buf, 0x20, 4) };
    let entsize = le(buf, if wide { 0x3a } else { 0x2e }, 2);
    let mut shnum = le(buf, if wide { 0x3c } else { 0x30 }, 2);
    if shoff == 0 {
        return; // no section header table, so no section
    }
    let min_entsize = if wide { 64 } else { 40 };
    if entsize < min_entsize {
        unread("section headers shorter than the format's");
    }
    if shoff > len || len - shoff < entsize {
        unread("section headers past the end of the file");
    }
    // More than 0xff00 sections: e_shnum is 0 and section 0's sh_size holds the count.
    if shnum == 0 {
        shnum = if wide { le(buf, shoff + 0x20, 8) } else { le(buf, shoff + 0x14, 4) };
    }
    if shnum > (len - shoff) / entsize {
        unread("section headers past the end of the file");
    }
    for i in 0..shnum {
        let at = shoff + i * entsize + 8;
        let flags = if wide { le(buf, at, 8) } else { le(buf, at, 4) };
        if flags & SHF_COMPRESSED != 0 {
            fail(&cat(&[
                path,
                format!(": section {i} is compressed (SHF_COMPRESSED, flags 0x{flags:x}): its bytes are not the strings it holds, so a directory in it cannot be found; the file is left unchanged").as_bytes(),
            ]));
        }
    }
}

/// The offset of the first occurrence of `needle` in `hay` at or after `at`.
fn index_of_pos(hay: &[u8], at: usize, needle: &[u8]) -> Option<usize> {
    if at > hay.len() || hay.len() - at < needle.len() {
        return None;
    }
    hay[at..]
        .windows(needle.len())
        .position(|w| w == needle)
        .map(|i| at + i)
}

/// Rewrites every occurrence of `dir` in `buf` followed by '/' or NUL, in
/// place, and returns how many there were. Refuses (exit 1) before writing
/// anything when one occurrence is followed by anything else.
fn relocate(path: &[u8], buf: &mut [u8], dir: &[u8]) -> usize {
    let mut found = Vec::new();
    let mut at = 0;
    // First pass: find and check every occurrence; nothing is written yet.
    while let Some(i) = index_of_pos(buf, at, dir) {
        let next = i + dir.len();
        if next >= buf.len() {
            fail(&cat(&[
                path,
                b": ",
                dir,
                format!(" at offset {i} ends the file; it is not followed by '/' or NUL, so the file is left unchanged").as_bytes(),
            ]));
        }
        let b = buf[next];
        if b != b'/' && b != 0 {
            fail(&cat(&[
                path,
                b": ",
                dir,
                format!(" at offset {i} is followed by byte 0x{b:02x}, not '/' or NUL, so the file is left unchanged").as_bytes(),
            ]));
        }
        found.push(i);
        at = next;
    }
    // Second pass: the same occurrences, rewritten.
    for &i in &found {
        buf[i] = b'/';
        buf[i + 1..i + dir.len()].fill(b'_');
    }
    found.len()
}

/// A temporary file beside the file it will replace, removed on drop unless
/// it was renamed over that file.
struct Temp {
    path: PathBuf,
    renamed: bool,
}

impl Drop for Temp {
    fn drop(&mut self) {
        if !self.renamed {
            let _ = fs::remove_file(&self.path);
        }
    }
}

/// A 16-character name from 12 random bytes in base64url, as Zig's
/// AtomicFile names its temporary file.
fn temp_name() -> OsString {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut bytes = Vec::with_capacity(16);
    let mut h = RandomState::new().build_hasher();
    h.write_u32(process::id());
    let mut bits = h.finish() as u128 | ((RandomState::new().build_hasher().finish() as u128) << 64);
    for _ in 0..16 {
        bytes.push(ALPHABET[(bits & 63) as usize]);
        bits >>= 6;
    }
    OsString::from_vec(bytes)
}

/// Replaces the file at `path` with `buf` through a temporary file in its
/// directory, renamed over it, with permission bits `mode` set exactly. A
/// failure returns the step it failed at and the Zig name of its error; the
/// temporary file is then removed.
fn replace(path: &Path, buf: &[u8], mode: u32) -> Result<(), (&'static str, &'static str)> {
    let dir = match path.parent() {
        Some(d) if !d.as_os_str().is_empty() => d.to_path_buf(),
        _ => PathBuf::from("."),
    };
    let (mut file, mut temp) = loop {
        let tmp = dir.join(temp_name());
        match OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(mode)
            .open(&tmp)
        {
            Ok(f) => break (f, Temp { path: tmp, renamed: false }),
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(("temporary file", zig_name(Call::Open, &e))),
        }
    };
    file.write_all(buf)
        .map_err(|e| ("write", zig_name(Call::Write, &e)))?;
    // The creation mode passed the umask; set the bits exactly.
    file.set_permissions(fs::Permissions::from_mode(mode))
        .map_err(|e| ("chmod", zig_name(Call::Chmod, &e)))?;
    drop(file);
    fs::rename(&temp.path, path).map_err(|e| ("rename", zig_name(Call::Rename, &e)))?;
    temp.renamed = true;
    Ok(())
}

fn main() {
    let argv: Vec<Vec<u8>> = std::env::args_os().map(|a| a.into_vec()).collect();
    if argv.len() < 3 {
        usage_fail(b"expected a file and at least one directory");
    }
    let path_b = &argv[1];
    let dirs = &argv[2..];
    for d in dirs {
        if d.len() < MIN_DIR_LEN {
            usage_fail(&cat(&[
                b"directory '",
                d,
                format!("' is {} bytes long, under {MIN_DIR_LEN}", d.len()).as_bytes(),
            ]));
        }
        if d[0] != b'/' {
            usage_fail(&cat(&[b"directory '", d, b"' is not absolute"]));
        }
        if d[d.len() - 1] == b'/' {
            usage_fail(&cat(&[b"directory '", d, b"' ends with '/'"]));
        }
    }
    let path = Path::new(std::ffi::OsStr::from_bytes(path_b));
    let io_fail = |call: Call, e: io::Error| -> ! {
        fail(&cat(&[path_b, b": ", zig_name(call, &e).as_bytes()]))
    };

    // A symbolic link is refused: the rename would replace the link with a
    // regular file and leave its target as it was.
    match fs::read_link(path) {
        Ok(_) => fail(&cat(&[path_b, b" is a symbolic link; give the file it names"])),
        Err(e) => match zig_name(Call::Readlink, &e) {
            "NotLink" => {}
            _ => io_fail(Call::Readlink, e),
        },
    }
    let st = fs::metadata(path).unwrap_or_else(|e| io_fail(Call::Stat, e));
    let mut file = File::open(path).unwrap_or_else(|e| io_fail(Call::Open, e));
    let size = file.metadata().unwrap_or_else(|e| io_fail(Call::Stat, e)).len();
    if size > MAX_FILE {
        fail(&cat(&[path_b, b": FileTooBig"]));
    }
    let mut buf = Vec::with_capacity(size as usize);
    io::Read::read_to_end(&mut file, &mut buf).unwrap_or_else(|e| io_fail(Call::Read, e));
    drop(file);
    if buf.len() as u64 > MAX_FILE {
        fail(&cat(&[path_b, b": FileTooBig"]));
    }
    let before = buf.len();
    refuse_compressed(path_b, &buf);

    let mut counts = Vec::with_capacity(dirs.len());
    let mut total = 0;
    for d in dirs {
        let n = relocate(path_b, &mut buf, d);
        counts.push(n);
        total += n;
    }
    assert_eq!(buf.len(), before);

    // The counts go out before the file is replaced, so a failed write of
    // them (exit 1) leaves the file unchanged too.
    let mut out = io::stdout().lock();
    for (d, n) in dirs.iter().zip(&counts) {
        let line = cat(&[n.to_string().as_bytes(), b" ", d, b"\n"]);
        if let Err(e) = out.write_all(&line).and_then(|()| out.flush()) {
            fail(&cat(&[
                b"stdout: ",
                zig_name(Call::Write, &e).as_bytes(),
                b"; ",
                path_b,
                b" is unchanged",
            ]));
        }
    }
    drop(out);

    if total > 0 {
        if let Err((step, name)) = replace(path, &buf, st.permissions().mode() & 0o7777) {
            fail(&cat(&[path_b, b": ", step.as_bytes(), b": ", name.as_bytes(), b"; the file is unchanged"]));
        }
    }
}
