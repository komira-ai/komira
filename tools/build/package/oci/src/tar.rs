//! A tar reader, enough for an image layer: ustar, GNU long names and pax
//! extended headers; and the writer of the layer and archive `image` adds.
//!
//! Every header's checksum is verified. A layer must end with a zero block,
//! so a truncated layer is refused rather than read short. A long name, long
//! link or pax header is for the next entry only; one given twice before an
//! entry, or with no entry after it, is refused.

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Kind {
    File,
    Hardlink,
    Symlink,
    Dir,
    /// A device, a FIFO or another special entry: never a regular file.
    Other,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Entry {
    pub path: String,
    pub kind: Kind,
    pub mode: u32,
    pub size: u64,
    /// The target of a symbolic or hard link, else empty.
    pub link: String,
}

const BLOCK: usize = 512;

fn field(h: &[u8], at: usize, len: usize) -> &[u8] {
    let f = &h[at..at + len];
    match f.iter().position(|&b| b == 0) {
        Some(n) => &f[..n],
        None => f,
    }
}

fn text(b: &[u8], what: &str) -> Result<String, String> {
    String::from_utf8(b.to_vec()).map_err(|_| format!("tar: {} is not UTF-8", what))
}

/// An octal field (spaces and NULs around it allowed), or a base-256 one.
fn number(h: &[u8], at: usize, len: usize, what: &str) -> Result<u64, String> {
    let f = &h[at..at + len];
    if f[0] & 0x80 != 0 {
        let mut v: u64 = (f[0] & 0x7f) as u64;
        for &b in &f[1..] {
            v = v.checked_mul(256).and_then(|v| v.checked_add(b as u64)).ok_or_else(|| format!("tar: {} overflows", what))?;
        }
        return Ok(v);
    }
    let t: Vec<u8> = f.iter().copied().filter(|&b| b != 0 && b != b' ').collect();
    if t.is_empty() {
        return Ok(0);
    }
    let s = std::str::from_utf8(&t).map_err(|_| format!("tar: {} is not octal", what))?;
    u64::from_str_radix(s, 8).map_err(|_| format!("tar: {} `{}` is not octal", what, s))
}

/// The pax records `<len> <key>=<value>\n` of an extended header.
fn pax(data: &[u8]) -> Result<Vec<(String, String)>, String> {
    let mut out = Vec::new();
    let mut at = 0;
    while at < data.len() {
        let sp = data[at..].iter().position(|&b| b == b' ').ok_or("tar: a pax record without a length")?;
        let n: usize = std::str::from_utf8(&data[at..at + sp]).ok().and_then(|s| s.parse().ok()).ok_or("tar: a pax record length is not a number")?;
        if n <= sp + 1 || at + n > data.len() || data[at + n - 1] != b'\n' {
            return Err("tar: a malformed pax record".into());
        }
        let rec = &data[at + sp + 1..at + n - 1];
        let eq = rec.iter().position(|&b| b == b'=').ok_or("tar: a pax record without `=`")?;
        out.push((text(&rec[..eq], "a pax key")?, text(&rec[eq + 1..], "a pax value")?));
        at += n;
    }
    Ok(out)
}

pub fn read(data: &[u8]) -> Result<Vec<Entry>, String> {
    let mut out = Vec::new();
    let mut at = 0;
    let mut long_name: Option<String> = None;
    let mut long_link: Option<String> = None;
    let mut pax_kv: Option<Vec<(String, String)>> = None;
    loop {
        let h = data.get(at..at + BLOCK).ok_or("tar: the archive ends without a zero block")?;
        if h.iter().all(|&b| b == 0) {
            if long_name.is_some() || long_link.is_some() || pax_kv.is_some() {
                return Err("tar: the archive ends after a header for no entry".into());
            }
            return Ok(out);
        }
        let sum: u64 = h.iter().enumerate().map(|(i, &b)| if (148..156).contains(&i) { b' ' as u64 } else { b as u64 }).sum();
        if number(h, 148, 8, "checksum")? != sum {
            return Err(format!("tar: header at byte {} has a wrong checksum", at));
        }
        let flag = h[156];
        let mut size = number(h, 124, 12, "size")?;
        if !matches!(flag, b'L' | b'K' | b'x' | b'g') {
            if let Some((_, v)) = pax_kv.iter().flatten().find(|(k, _)| k == "size") {
                size = v.parse().map_err(|_| "tar: a pax size is not a number")?;
            }
        }
        let body = at + BLOCK;
        let end = body.checked_add(size as usize).filter(|&e| e <= data.len()).ok_or("tar: an entry runs past the end")?;
        let next = body + (size as usize).div_ceil(BLOCK) * BLOCK;
        match flag {
            b'L' if long_name.is_some() => return Err("tar: two long names for one entry".into()),
            b'K' if long_link.is_some() => return Err("tar: two long links for one entry".into()),
            b'x' if pax_kv.is_some() => return Err("tar: two pax headers for one entry".into()),
            b'L' => long_name = Some(text(field(&data[body..end], 0, end - body), "a long name")?),
            b'K' => long_link = Some(text(field(&data[body..end], 0, end - body), "a long link")?),
            b'x' => pax_kv = Some(pax(&data[body..end])?),
            // A global header changes no path of this layer that we read.
            b'g' => {}
            _ => {
                let mut path = text(field(h, 0, 100), "a name")?;
                // POSIX ustar only: GNU's `ustar  \0` keeps its atime there.
                if &h[257..263] == b"ustar\0" {
                    let prefix = text(field(h, 345, 155), "a name prefix")?;
                    if !prefix.is_empty() {
                        path = format!("{}/{}", prefix, path);
                    }
                }
                let mut link = text(field(h, 157, 100), "a link name")?;
                if let Some(n) = long_name.take() {
                    path = n;
                }
                if let Some(l) = long_link.take() {
                    link = l;
                }
                for (k, v) in pax_kv.take().unwrap_or_default() {
                    match k.as_str() {
                        "path" => path = v,
                        "linkpath" => link = v,
                        _ => {}
                    }
                }
                let kind = match flag {
                    b'0' | 0 | b'7' => Kind::File,
                    b'1' => Kind::Hardlink,
                    b'2' => Kind::Symlink,
                    b'5' => Kind::Dir,
                    _ => Kind::Other,
                };
                if kind != Kind::Symlink && kind != Kind::Hardlink {
                    link.clear();
                }
                let mode = (number(h, 100, 8, "mode")? & 0o7777) as u32;
                out.push(Entry { path, kind, mode, size, link });
            }
        }
        at = next;
    }
}

/// An entry to write: a directory's path ends in /.
pub struct Item {
    pub path: String,
    pub mode: u32,
    pub data: Vec<u8>,
}

/// Zero-padded octal filling all but the last byte, which is NUL.
fn octal(f: &mut [u8], v: u64) -> Result<(), String> {
    let digits = f.len() - 1;
    let s = format!("{:0w$o}", v, w = digits);
    if s.len() > digits {
        return Err(format!("tar: {} does not fit a {}-byte field", v, f.len()));
    }
    f[..digits].copy_from_slice(s.as_bytes());
    f[digits] = 0;
    Ok(())
}

fn put_header(out: &mut Vec<u8>, name: &[u8], flag: u8, mode: u32, size: u64) -> Result<(), String> {
    let mut h = [0u8; BLOCK];
    h[..name.len()].copy_from_slice(name);
    octal(&mut h[100..108], mode as u64)?;
    octal(&mut h[108..116], 0)?;
    octal(&mut h[116..124], 0)?;
    octal(&mut h[124..136], size)?;
    octal(&mut h[136..148], 0)?;
    h[156] = flag;
    h[257..263].copy_from_slice(b"ustar\0");
    h[263..265].copy_from_slice(b"00");
    h[148..156].copy_from_slice(b"        ");
    let sum: u64 = h.iter().map(|&b| b as u64).sum();
    octal(&mut h[148..155], sum)?;
    h[155] = b' ';
    out.extend_from_slice(&h);
    Ok(())
}

fn pad(out: &mut Vec<u8>) {
    out.resize(out.len().div_ceil(BLOCK) * BLOCK, 0);
}

/// `items` as a tar, sorted by path, uid, gid and mtime 0, a path over 100
/// bytes in a pax header, ending with two zero blocks. A path given twice
/// is refused.
pub fn write(mut items: Vec<Item>) -> Result<Vec<u8>, String> {
    items.sort_by(|a, b| a.path.as_bytes().cmp(b.path.as_bytes()));
    let mut out = Vec::new();
    for (i, e) in items.iter().enumerate() {
        if i > 0 && items[i - 1].path == e.path {
            return Err(format!("tar: {} given twice", e.path));
        }
        let flag = if e.path.ends_with('/') { b'5' } else { b'0' };
        let p = e.path.as_bytes();
        if p.len() > 100 {
            let mut len = " path=\n".len() + p.len();
            let mut digits = 1;
            while (len + digits).to_string().len() != digits {
                digits = (len + digits).to_string().len();
            }
            len += digits;
            let rec = format!("{} path={}\n", len, e.path);
            put_header(&mut out, b"././@PaxHeader", b'x', 0o644, rec.len() as u64)?;
            out.extend_from_slice(rec.as_bytes());
            pad(&mut out);
        }
        put_header(&mut out, &p[..p.len().min(100)], flag, e.mode, e.data.len() as u64)?;
        out.extend_from_slice(&e.data);
        pad(&mut out);
    }
    out.resize(out.len() + 2 * BLOCK, 0);
    Ok(out)
}

/// Test fixtures: a tar writer (ustar, and pax for a long name).
#[cfg(test)]
pub mod write {
    pub fn header(name: &str, flag: u8, mode: u32, size: usize, link: &str) -> Vec<u8> {
        let mut h = vec![0u8; 512];
        h[..name.len()].copy_from_slice(name.as_bytes());
        h[100..108].copy_from_slice(format!("{:07o}\0", mode).as_bytes());
        h[124..136].copy_from_slice(format!("{:011o}\0", size).as_bytes());
        h[156] = flag;
        h[157..157 + link.len()].copy_from_slice(link.as_bytes());
        h[257..263].copy_from_slice(b"ustar\0");
        h[263..265].copy_from_slice(b"00");
        h[148..156].copy_from_slice(b"        ");
        let sum: u32 = h.iter().map(|&b| b as u32).sum();
        h[148..156].copy_from_slice(format!("{:06o}\0 ", sum).as_bytes());
        h
    }

    pub fn entry(out: &mut Vec<u8>, name: &str, flag: u8, mode: u32, data: &[u8], link: &str) {
        out.extend(header(name, flag, mode, data.len(), link));
        out.extend_from_slice(data);
        out.resize(out.len().div_ceil(512) * 512, 0);
    }

    /// Entries `(path, flag, mode, data, link)`, then the two zero blocks.
    pub fn tar(entries: &[(&str, u8, u32, &[u8], &str)]) -> Vec<u8> {
        let mut out = Vec::new();
        for (p, f, m, d, l) in entries {
            entry(&mut out, p, *f, *m, d, l);
        }
        out.resize(out.len() + 1024, 0);
        out
    }
}

#[cfg(test)]
mod tests {
    use super::write::*;
    use super::*;

    #[test]
    fn reads_files_dirs_links_and_modes() {
        let t = tar(&[
            ("etc/", b'5', 0o755, b"", ""),
            ("etc/a", b'0', 0o644, b"hello", ""),
            ("bin/sh", b'0', 0o4755, b"x", ""),
            ("etc/b", b'2', 0o777, b"", "a"),
            ("etc/c", b'1', 0o644, b"", "etc/a"),
            ("dev/null", b'3', 0o666, b"", ""),
        ]);
        let e = read(&t).unwrap();
        let got: Vec<_> = e.iter().map(|e| (e.path.as_str(), e.kind, e.mode, e.size, e.link.as_str())).collect();
        assert_eq!(
            got,
            [
                ("etc/", Kind::Dir, 0o755, 0, ""),
                ("etc/a", Kind::File, 0o644, 5, ""),
                ("bin/sh", Kind::File, 0o4755, 1, ""),
                ("etc/b", Kind::Symlink, 0o777, 0, "a"),
                ("etc/c", Kind::Hardlink, 0o644, 0, "etc/a"),
                ("dev/null", Kind::Other, 0o666, 0, ""),
            ]
        );
    }

    #[test]
    fn reads_a_pax_path_and_a_gnu_long_name() {
        let long = "d/".repeat(70) + "f";
        let rec = format!(" path={}\n", long);
        let rec = format!("{}{}", rec.len() + (rec.len() + 3).to_string().len(), rec);
        let mut t = Vec::new();
        entry(&mut t, "PaxHeader", b'x', 0o644, rec.as_bytes(), "");
        entry(&mut t, "short", b'0', 0o755, b"ab", "");
        entry(&mut t, "././@LongLink", b'L', 0o644, format!("{}2\0", long).as_bytes(), "");
        entry(&mut t, "short2", b'0', 0o644, b"", "");
        t.resize(t.len() + 1024, 0);
        let e = read(&t).unwrap();
        assert_eq!(e[0].path, long);
        assert_eq!((e[0].mode, e[0].size), (0o755, 2));
        assert_eq!(e[1].path, long + "2");
    }

    #[test]
    fn writes_what_it_reads_back_sorted() {
        let long = "d/".repeat(60) + "file";
        let item = |p: &str, m: u32, d: &[u8]| Item { path: p.to_string(), mode: m, data: d.to_vec() };
        let t = write(vec![item("b", 0o644, b"bee"), item(&long, 0o755, b"x"), item("a/", 0o755, b"")]).unwrap();
        assert_eq!(t.len() % 512, 0);
        let got: Vec<_> = read(&t).unwrap().into_iter().map(|e| (e.path, e.kind, e.mode, e.size)).collect();
        assert_eq!(got, [("a/".to_string(), Kind::Dir, 0o755, 0), ("b".to_string(), Kind::File, 0o644, 3), (long.clone(), Kind::File, 0o755, 1)]);
        // The same items give the same bytes; uid, gid and mtime are 0.
        assert_eq!(t, write(vec![item("a/", 0o755, b""), item(&long, 0o755, b"x"), item("b", 0o644, b"bee")]).unwrap());
        assert_eq!(&t[136..148], b"00000000000\0");
        assert!(write(vec![item("a", 0o644, b""), item("a", 0o755, b"")]).unwrap_err().contains("a given twice"));
        // Two zero blocks end it, after the last entry's data block.
        assert!(t[t.len() - 1024..].iter().all(|&b| b == 0));
        assert_eq!(t[t.len() - 1536], b'x');
    }

    /// The header's checksum written again after an edit, as `%07o\0`
    /// (byte 155 NUL: the sum must count all eight checksum bytes as spaces).
    fn resum(h: &mut [u8]) {
        h[148..156].copy_from_slice(b"        ");
        let sum: u32 = h[..512].iter().map(|&b| b as u32).sum();
        h[148..156].copy_from_slice(format!("{:07o}\0", sum).as_bytes());
    }

    fn end(mut t: Vec<u8>) -> Vec<u8> {
        t.resize(t.len() + 1024, 0);
        t
    }

    fn with_pax(rec: &[u8]) -> Result<Vec<Entry>, String> {
        let mut t = Vec::new();
        entry(&mut t, "PaxHeader", b'x', 0o644, rec, "");
        entry(&mut t, "f", b'0', 0o644, b"", "");
        read(&end(t))
    }

    #[test]
    fn each_malformed_pax_record_is_refused() {
        for (rec, why) in [
            (&b"abc"[..], "tar: a pax record without a length"),
            (b"x path=a\n", "tar: a pax record length is not a number"),
            (b"9 a=b\n", "tar: a malformed pax record"),
            (b"7 a=b\n", "tar: a malformed pax record"),
            (b"6 a=bX", "tar: a malformed pax record"),
            (b"2 \n", "tar: a malformed pax record"),
            (b"0 a=b\n", "tar: a malformed pax record"),
            (b"5 ab\n", "tar: a pax record without `=`"),
            (b"6 \xff=b\n", "tar: a pax key is not UTF-8"),
            (b"7 a=\xffb\n", "tar: a pax value is not UTF-8"),
            (b"9 size=x\n", "tar: a pax size is not a number"),
        ] {
            assert_eq!(with_pax(rec), Err(why.to_string()), "{:?}", String::from_utf8_lossy(rec));
        }
        // Every record is read, not only the first.
        assert_eq!(with_pax(b"6 a=b\n12 path=xyz\n").unwrap()[0].path, "xyz");
    }

    #[test]
    fn a_pax_size_is_the_size_of_the_next_entry_only() {
        // The header says 0; the pax record says 3.
        let mut t = Vec::new();
        entry(&mut t, "PaxHeader", b'x', 0o644, b"10 size=3\n", "");
        t.extend(header("f", b'0', 0o644, 0, ""));
        t.extend(b"abc");
        t.resize(t.len().div_ceil(512) * 512, 0);
        entry(&mut t, "g", b'0', 0o644, b"z", "");
        let e = read(&end(t)).unwrap();
        assert_eq!(e.iter().map(|e| (e.path.as_str(), e.size)).collect::<Vec<_>>(), [("f", 3), ("g", 1)]);
        // Not the size of a long-name header that comes between.
        let long = "n".repeat(120);
        let mut t = Vec::new();
        entry(&mut t, "PaxHeader", b'x', 0o644, b"10 size=2\n", "");
        entry(&mut t, "././@LongLink", b'L', 0o644, long.as_bytes(), "");
        t.extend(header("short", b'0', 0o644, 0, ""));
        t.extend(b"ab");
        t.resize(t.len().div_ceil(512) * 512, 0);
        let e = read(&end(t)).unwrap();
        assert_eq!((e[0].path.as_str(), e[0].size), (long.as_str(), 2));
    }

    #[test]
    fn numbers_are_octal_or_base_256() {
        let one = |edit: &dyn Fn(&mut [u8])| {
            let mut h = header("f", b'0', 0o644, 0, "");
            edit(&mut h);
            resum(&mut h);
            h.resize(512 + 1024 + 512, 0);
            read(&h)
        };
        // Base-256: 0x80 then big-endian bytes.
        assert_eq!(one(&|h| {
            h[124..136].fill(0);
            h[124] = 0x80;
            h[135] = 3;
        }).unwrap()[0].size, 3);
        // Every byte counts, at its place.
        assert_eq!(one(&|h| {
            h[124..136].fill(0);
            h[124] = 0x80;
            h[134] = 1;
            h[135] = 2;
        }).unwrap()[0].size, 258);
        assert_eq!(one(&|h| h[124..136].fill(0xff)), Err("tar: size overflows".into()));
        // The first byte's low bits are the top of the number: 2^88 overflows.
        assert_eq!(one(&|h| {
            h[124..136].fill(0);
            h[124] = 0x81;
        }), Err("tar: size overflows".into()));
        assert_eq!(one(&|h| h[124..136].copy_from_slice(b"00000000z0\0\0")), Err("tar: size `00000000z0` is not octal".into()));
        assert_eq!(one(&|h| h[124..136].copy_from_slice(b"0000000000\xff\0")), Err("tar: size is not octal".into()));
        // NULs and spaces around the digits; an empty field is 0.
        assert_eq!(one(&|h| h[100..108].copy_from_slice(b" 644 \0\0\0")).unwrap()[0].mode, 0o644);
        assert_eq!(one(&|h| h[100..108].fill(0)).unwrap()[0].mode, 0);
        // The mode keeps its low twelve bits.
        assert_eq!(one(&|h| h[100..108].copy_from_slice(b"0104755\0")).unwrap()[0].mode, 0o4755);
        // A name that is not UTF-8.
        assert_eq!(one(&|h| h[0] = 0xff), Err("tar: a name is not UTF-8".into()));
    }

    #[test]
    fn names_links_and_kinds() {
        let mut t = Vec::new();
        // A ustar prefix is joined to the name; without the ustar magic it is not read.
        let mut h = header("c", b'0', 0o644, 0, "");
        h[345..348].copy_from_slice(b"a/b");
        resum(&mut h);
        t.extend(&h);
        h[257..263].fill(0);
        resum(&mut h);
        t.extend(&h);
        // Only links keep a link name; NUL and '7' are files; a global header is no entry.
        entry(&mut t, "file", b'0', 0o644, b"", "x");
        entry(&mut t, "dir/", b'5', 0o755, b"", "x");
        entry(&mut t, "hard", b'1', 0o644, b"", "file");
        entry(&mut t, "nul", 0, 0o644, b"", "");
        entry(&mut t, "contig", b'7', 0o644, b"", "");
        entry(&mut t, "global", b'g', 0o644, b"11 path=zz\n", "");
        let long = "t".repeat(130);
        entry(&mut t, "././@LongLink", b'K', 0o644, long.as_bytes(), "");
        entry(&mut t, "sym", b'2', 0o777, b"", "short");
        let got: Vec<_> = read(&end(t)).unwrap().into_iter().map(|e| (e.path, e.kind, e.link)).collect();
        let want: Vec<(String, Kind, String)> = [
            ("a/b/c", Kind::File, ""),
            ("c", Kind::File, ""),
            ("file", Kind::File, ""),
            ("dir/", Kind::Dir, ""),
            ("hard", Kind::Hardlink, "file"),
            ("nul", Kind::File, ""),
            ("contig", Kind::File, ""),
            ("sym", Kind::Symlink, long.as_str()),
        ]
        .iter()
        .map(|(p, k, l)| (p.to_string(), *k, l.to_string()))
        .collect();
        assert_eq!(got, want);
    }

    /// A pax record `<len> <key>=<value>\n`, its length counting itself.
    fn rec(k: &str, v: &str) -> String {
        let body = format!(" {}={}\n", k, v);
        let mut n = body.len() + 1;
        while body.len() + n.to_string().len() != n {
            n = body.len() + n.to_string().len();
        }
        format!("{}{}", n, body)
    }

    #[test]
    fn a_long_name_long_link_or_pax_header_is_for_the_next_entry_only() {
        let (long, long2) = ("n".repeat(120), "m/".repeat(60) + "x");
        let (target, target2) = ("t/".repeat(60) + "x", "u".repeat(150));
        let mut t = Vec::new();
        entry(&mut t, "././@LongLink", b'L', 0o644, long.as_bytes(), "");
        entry(&mut t, "a", b'0', 0o644, b"", "");
        entry(&mut t, "b", b'0', 0o644, b"", "");
        entry(&mut t, "././@LongLink", b'K', 0o644, target.as_bytes(), "");
        entry(&mut t, "l1", b'2', 0o777, b"", "s1");
        entry(&mut t, "l2", b'2', 0o777, b"", "s2");
        entry(&mut t, "PaxHeader", b'x', 0o644, (rec("path", &long2) + &rec("linkpath", &target2)).as_bytes(), "");
        entry(&mut t, "l3", b'2', 0o777, b"", "s3");
        entry(&mut t, "l4", b'2', 0o777, b"", "s4");
        let got: Vec<(String, String)> = read(&end(t)).unwrap().into_iter().map(|e| (e.path, e.link)).collect();
        let want: Vec<(String, String)> = [(long.as_str(), ""), ("b", ""), ("l1", target.as_str()), ("l2", "s2"), (long2.as_str(), target2.as_str()), ("l4", "s4")]
            .iter()
            .map(|(p, l)| (p.to_string(), l.to_string()))
            .collect();
        assert_eq!(got, want);
    }

    #[test]
    fn a_header_for_the_next_entry_comes_once_and_is_followed_by_one() {
        let long = |flag: u8| -> Vec<u8> {
            let mut t = Vec::new();
            entry(&mut t, "././@LongLink", flag, 0o644, b"long", "");
            t
        };
        let pax = || {
            let mut t = Vec::new();
            entry(&mut t, "PaxHeader", b'x', 0o644, b"", "");
            t
        };
        let then = |mut t: Vec<u8>, more: Vec<u8>| {
            t.extend(more);
            entry(&mut t, "f", b'2', 0o777, b"", "x");
            read(&end(t))
        };
        assert_eq!(then(long(b'L'), long(b'L')), Err("tar: two long names for one entry".into()));
        assert_eq!(then(long(b'K'), long(b'K')), Err("tar: two long links for one entry".into()));
        // An empty pax header is a header all the same.
        assert_eq!(then(pax(), pax()), Err("tar: two pax headers for one entry".into()));
        // One of each kind is fine; a global header is none of them.
        let mut g = Vec::new();
        entry(&mut g, "global", b'g', 0o644, b"", "");
        let mut all = long(b'K');
        all.extend(pax());
        all.extend(g);
        let e = then(long(b'L'), all).unwrap();
        assert_eq!((e[0].path.as_str(), e[0].link.as_str()), ("long", "long"));
        // A header with no entry after it: the archive was cut short.
        for t in [long(b'L'), long(b'K'), pax()] {
            assert_eq!(read(&end(t)), Err("tar: the archive ends after a header for no entry".into()));
        }
    }

    #[test]
    fn a_gnu_header_has_no_name_prefix() {
        // GNU's magic is `ustar  \0`; bytes 345.. hold its atime, not a prefix.
        let mut h = header("c", b'0', 0o644, 0, "");
        h[257..265].copy_from_slice(b"ustar  \0");
        h[345..357].copy_from_slice(b"15000000000\0");
        resum(&mut h);
        assert_eq!(read(&end(h)).unwrap()[0].path, "c");
    }

    #[test]
    fn an_entry_ending_at_the_archive_end_still_wants_a_zero_block() {
        let mut t = header("f", b'0', 0o644, 2000, "");
        t.resize(512 + 1024, 0);
        assert_eq!(read(&t), Err("tar: an entry runs past the end".into()));
        // One byte past the end.
        let mut t = header("f", b'0', 0o644, 513, "");
        t.resize(1024, 1);
        assert_eq!(read(&t), Err("tar: an entry runs past the end".into()));
        let mut t = header("f", b'0', 0o644, 512, "");
        t.resize(1024, 1);
        assert_eq!(read(&t), Err("tar: the archive ends without a zero block".into()));
    }

    #[test]
    fn long_paths_round_trip_at_every_length_boundary() {
        // 100 bytes fits the header; 101 takes a pax record, whose length
        // field grows from 3 to 4 digits between 989 and 990 bytes of path.
        for n in [99, 100, 101, 102, 988, 989, 990, 991] {
            let path = "p".repeat(n);
            let t = write(vec![Item { path: path.clone(), mode: 0o644, data: b"d".to_vec() }]).unwrap();
            let e = read(&t).unwrap();
            assert_eq!((e.len(), e[0].path.len(), e[0].size), (1, n, 1), "{}", n);
        }
        let mut f = [0u8; 8];
        assert_eq!(octal(&mut f, 0o7777777), Ok(()));
        assert_eq!(&f, b"7777777\0");
        assert_eq!(octal(&mut f, 0o10000000), Err("tar: 2097152 does not fit a 8-byte field".into()));
        assert!(write(vec![Item { path: "a".into(), mode: 0o10000000, data: vec![] }]).is_err());
    }

    #[test]
    fn refuses_a_bad_checksum_and_a_truncated_archive() {
        let mut t = tar(&[("a", b'0', 0o644, b"x", "")]);
        t[0] = b'b';
        assert!(read(&t).unwrap_err().contains("checksum"));
        let t = tar(&[("a", b'0', 0o644, b"x", "")]);
        assert!(read(&t[..1024]).unwrap_err().contains("zero block"));
        assert!(read(&t[..600]).is_err());
    }
}
