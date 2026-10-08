//! A tar reader, enough for an image layer: ustar, GNU long names and pax
//! extended headers.
//!
//! Every header's checksum is verified. A layer must end with a zero block,
//! so a truncated layer is refused rather than read short.

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
    let mut pax_kv: Vec<(String, String)> = Vec::new();
    loop {
        let h = data.get(at..at + BLOCK).ok_or("tar: the archive ends without a zero block")?;
        if h.iter().all(|&b| b == 0) {
            return Ok(out);
        }
        let sum: u64 = h.iter().enumerate().map(|(i, &b)| if (148..156).contains(&i) { b' ' as u64 } else { b as u64 }).sum();
        if number(h, 148, 8, "checksum")? != sum {
            return Err(format!("tar: header at byte {} has a wrong checksum", at));
        }
        let flag = h[156];
        let mut size = number(h, 124, 12, "size")?;
        if !matches!(flag, b'L' | b'K' | b'x' | b'g') {
            if let Some((_, v)) = pax_kv.iter().find(|(k, _)| k == "size") {
                size = v.parse().map_err(|_| "tar: a pax size is not a number")?;
            }
        }
        let body = at + BLOCK;
        let end = body.checked_add(size as usize).filter(|&e| e <= data.len()).ok_or("tar: an entry runs past the end")?;
        let next = body + (size as usize).div_ceil(BLOCK) * BLOCK;
        match flag {
            b'L' => long_name = Some(text(field(&data[body..end], 0, end - body), "a long name")?),
            b'K' => long_link = Some(text(field(&data[body..end], 0, end - body), "a long link")?),
            b'x' => pax_kv = pax(&data[body..end])?,
            // A global header changes no path of this layer that we read.
            b'g' => {}
            _ => {
                let mut path = text(field(h, 0, 100), "a name")?;
                if &h[257..262] == b"ustar" {
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
                for (k, v) in pax_kv.drain(..) {
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
    fn refuses_a_bad_checksum_and_a_truncated_archive() {
        let mut t = tar(&[("a", b'0', 0o644, b"x", "")]);
        t[0] = b'b';
        assert!(read(&t).unwrap_err().contains("checksum"));
        let t = tar(&[("a", b'0', 0o644, b"x", "")]);
        assert!(read(&t[..1024]).unwrap_err().contains("zero block"));
        assert!(read(&t[..600]).is_err());
    }
}
