//! Stores each answer under a hash of everything that produced it: the state
//! the model saw (path and numbered contents), the question asked of it, and
//! the model. Changing any of them is a miss. Safe to share across threads.
//!
//! The file is a log: a header, then a record per answer, its 32-byte key,
//! how many probabilities it has (u32), and each as an f64, little-endian.
//! Opening it indexes the keys and leaves the probabilities on disk until
//! they're asked for. New answers are appended, and a later record replaces
//! an earlier one with the same key. A record cut short by a killed run is
//! dropped before the next append.

use std::fs::{self, File, OpenOptions};
use std::io::{BufReader, BufWriter, Read, Write};
use std::os::unix::fs::FileExt;
use std::sync::Mutex;

use anyhow::{Context, Result};
use sha2::{Digest, Sha256};

pub type Key = [u8; 32];

const HEADER: &[u8; 8] = b"jlcache1";
/// An index entry's offset is shifted past its count.
const COUNT_BITS: u32 = 24;

pub struct Cache {
    path: Option<String>,
    file: Option<File>,
    /// Keys, sorted, each with its probabilities' offset and count.
    index: Vec<(Key, u64)>,
    /// Where the last whole record ends, or 0 when the file isn't a cache.
    end: u64,
    out: Mutex<Option<BufWriter<File>>>,
}

pub fn key(question_digest: &str, state_digest: &str, model: &str) -> Key {
    Sha256::digest(format!("{question_digest}:{state_digest}:{model}")).into()
}

impl Cache {
    /// No path, under --no-cache, keeps nothing.
    pub fn open(path: Option<&str>) -> Result<Cache> {
        let mut cache =
            Cache { path: path.map(str::to_string), file: None, index: Vec::new(), end: 0, out: Mutex::new(None) };
        if let Some(path) = path.filter(|p| std::path::Path::new(p).exists()) {
            let file = File::open(path).with_context(|| format!("Couldn't read {path}"))?;
            (cache.index, cache.end) = index(&file).with_context(|| format!("Couldn't read {path}"))?;
            cache.file = Some(file);
        }
        Ok(cache)
    }

    pub fn get(&self, key: &Key) -> Result<Option<Vec<f64>>> {
        let (Ok(i), Some(file)) = (self.index.binary_search_by(|(k, _)| k.cmp(key)), &self.file) else {
            return Ok(None);
        };
        let place = self.index[i].1;
        let mut bytes = vec![0u8; (place & ((1 << COUNT_BITS) - 1)) as usize * 8];
        file.read_exact_at(&mut bytes, place >> COUNT_BITS)?;
        Ok(Some(bytes.chunks_exact(8).map(|b| f64::from_le_bytes(b.try_into().unwrap())).collect()))
    }

    pub fn put(&self, key: &Key, values: &[f64]) -> Result<()> {
        let Some(path) = &self.path else { return Ok(()) };
        let mut out = self.out.lock().unwrap_or_else(|e| e.into_inner());
        if out.is_none() {
            *out = Some(BufWriter::with_capacity(1 << 20, self.append(path)?));
        }
        let out = out.as_mut().expect("opened above");
        out.write_all(key)?;
        out.write_all(&(values.len() as u32).to_le_bytes())?;
        for value in values {
            out.write_all(&value.to_le_bytes())?;
        }
        Ok(())
    }

    /// Writes out the answers put so far.
    pub fn flush(&self) -> Result<()> {
        if let Some(out) = self.out.lock().unwrap_or_else(|e| e.into_inner()).as_mut() {
            out.flush().context("Couldn't save the cache")?;
        }
        Ok(())
    }

    fn append(&self, path: &str) -> Result<File> {
        if let Some(dir) = std::path::Path::new(path).parent() {
            fs::create_dir_all(dir)?;
        }
        let mut file = OpenOptions::new().create(true).append(true).open(path)?;
        if file.metadata()?.len() != self.end {
            file.set_len(self.end)?;
        }
        if self.end == 0 {
            file.write_all(HEADER)?;
        }
        Ok(file)
    }
}

/// The keys in a cache file, sorted, with the latest of any key stored twice,
/// and where its last whole record ends.
fn index(file: &File) -> Result<(Vec<(Key, u64)>, u64)> {
    let length = file.metadata()?.len();
    let mut reader = BufReader::with_capacity(1 << 20, file);
    let mut header = [0u8; 8];
    if reader.read_exact(&mut header).is_err() || &header != HEADER {
        return Ok((Vec::new(), 0));
    }
    let mut index: Vec<(Key, u64)> = Vec::new();
    let mut at = HEADER.len() as u64;
    let mut record = [0u8; 36];
    while at + 36 <= length && reader.read_exact(&mut record).is_ok() {
        let count = u32::from_le_bytes(record[32..].try_into().unwrap()) as u64;
        let next = at + 36 + count * 8;
        if next > length || count >= 1 << COUNT_BITS {
            break;
        }
        index.push((record[..32].try_into().unwrap(), ((at + 36) << COUNT_BITS) | count));
        reader.seek_relative(count as i64 * 8)?;
        at = next;
    }
    // Latest first, so a stable sort and dedup keep it.
    index.reverse();
    index.sort_by_key(|entry| entry.0);
    index.dedup_by(|a, b| a.0 == b.0);
    Ok((index, at))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stores_reads_and_replaces() {
        let dir = std::env::temp_dir().join(format!("judgelint-cache-{}", std::process::id()));
        let path = dir.join("cache.bin");
        let path = path.to_str().unwrap();
        let (a, b) = (key("q", "s", "m"), key("q2", "s", "m"));
        let cache = Cache::open(Some(path)).unwrap();
        cache.put(&a, &[0.9]).unwrap();
        cache.put(&b, &[0.1, 0.2, 0.7]).unwrap();
        cache.flush().unwrap();
        drop(cache);
        let cache = Cache::open(Some(path)).unwrap();
        assert_eq!(cache.get(&a).unwrap(), Some(vec![0.9]));
        assert_eq!(cache.get(&b).unwrap(), Some(vec![0.1, 0.2, 0.7]));
        cache.put(&a, &[0.3]).unwrap();
        cache.flush().unwrap();
        drop(cache);
        // A torn record at the end is dropped.
        OpenOptions::new().append(true).open(path).unwrap().write_all(&[1, 2, 3]).unwrap();
        let cache = Cache::open(Some(path)).unwrap();
        assert_eq!(cache.get(&a).unwrap(), Some(vec![0.3]));
        cache.put(&b, &[0.5]).unwrap();
        cache.flush().unwrap();
        drop(cache);
        let cache = Cache::open(Some(path)).unwrap();
        assert_eq!(cache.get(&b).unwrap(), Some(vec![0.5]));
        fs::remove_dir_all(dir).unwrap();
    }
}
