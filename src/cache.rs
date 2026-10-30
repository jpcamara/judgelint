//! Stores each answer under a hash of everything that produced it: the state
//! the model saw (path and numbered contents), the question asked of it, and
//! the model. Changing any of them is a miss. Safe to share across threads.
//!
//! The file is a log: a header, then a record per answer, its 32-byte key,
//! how many probabilities it has (u32), and each as an f64, little-endian.
//! Opening it indexes the keys and leaves the probabilities on disk until
//! they're asked for. New answers are appended, and a later record replaces
//! an earlier one with the same key. Runs that share a cache take turns
//! appending, under a lock, and keep each other's records; a record cut short
//! by a killed run is dropped before the next append. A file that isn't a
//! cache is an error, never overwritten.

use std::fs::{self, File, OpenOptions};
use std::io::{BufReader, Cursor, Read, Seek};
use std::os::unix::fs::{FileExt, MetadataExt};
use std::sync::Mutex;

use anyhow::{Context, Result, bail};
use sha2::{Digest, Sha256};

pub type Key = [u8; 32];

const HEADER: &[u8; 8] = b"jlcache1";
/// An index entry's offset is shifted past its count.
const COUNT_BITS: u32 = 24;
/// Answers are written out when this much has been put, and at the end.
const PENDING_BYTES: usize = 1 << 20;

pub struct Cache {
    path: Option<String>,
    /// What was indexed: the file, or a cache read from a commit.
    store: Option<Store>,
    /// Keys, sorted, each with its probabilities' offset and count.
    index: Vec<(Key, u64)>,
    /// Where the last whole record ended when it was indexed, or 0 when the
    /// file was new or empty.
    end: u64,
    /// Records put since they were last written out.
    pending: Mutex<Vec<u8>>,
}

enum Store {
    File(File),
    Memory(Vec<u8>),
}

impl Store {
    fn read_exact_at(&self, buffer: &mut [u8], offset: u64) -> std::io::Result<()> {
        match self {
            Store::File(file) => file.read_exact_at(buffer, offset),
            Store::Memory(bytes) => {
                let start = usize::try_from(offset).unwrap_or(usize::MAX);
                let found = bytes.get(start..start.saturating_add(buffer.len()));
                buffer.copy_from_slice(found.ok_or(std::io::ErrorKind::UnexpectedEof)?);
                Ok(())
            }
        }
    }
}

pub fn key(question_digest: &str, state_digest: &str, model: &str) -> Key {
    Sha256::digest(format!("{question_digest}:{state_digest}:{model}")).into()
}

impl Cache {
    /// No path, under --no-cache, keeps nothing.
    pub fn open(path: Option<&str>) -> Result<Cache> {
        let mut cache =
            Cache { path: path.map(str::to_string), store: None, index: Vec::new(), end: 0, pending: Mutex::default() };
        if let Some(path) = path {
            refuse_link(path)?;
        }
        if let Some(path) = path.filter(|p| std::path::Path::new(p).exists()) {
            let file = File::open(path).with_context(|| format!("Couldn't read {path}"))?;
            let length = file.metadata()?.len();
            (cache.index, cache.end) = index(BufReader::with_capacity(1 << 20, &file), length)
                .with_context(|| format!("Couldn't read {path}"))?;
            cache.store = Some(Store::File(file));
        }
        Ok(cache)
    }

    /// A cache read from a commit, kept in memory: what's put in it is never
    /// written anywhere.
    pub fn in_memory(bytes: Vec<u8>) -> Result<Cache> {
        let (index, end) = index(Cursor::new(&bytes), bytes.len() as u64).context("Couldn't read the cache")?;
        Ok(Cache { path: None, store: Some(Store::Memory(bytes)), index, end, pending: Mutex::default() })
    }

    pub fn get(&self, key: &Key) -> Result<Option<Vec<f64>>> {
        let (Ok(i), Some(store)) = (self.index.binary_search_by(|(k, _)| k.cmp(key)), &self.store) else {
            return Ok(None);
        };
        let place = self.index[i].1;
        let mut bytes = vec![0u8; (place & ((1 << COUNT_BITS) - 1)) as usize * 8];
        store.read_exact_at(&mut bytes, place >> COUNT_BITS)?;
        Ok(Some(bytes.as_chunks::<8>().0.iter().map(|b| f64::from_le_bytes(*b)).collect()))
    }

    pub fn put(&self, key: &Key, values: &[f64]) -> Result<()> {
        if self.path.is_none() {
            return Ok(());
        }
        let mut pending = self.pending.lock().unwrap_or_else(|e| e.into_inner());
        pending.extend_from_slice(key);
        pending.extend_from_slice(&(values.len() as u32).to_le_bytes());
        for value in values {
            pending.extend_from_slice(&value.to_le_bytes());
        }
        if pending.len() >= PENDING_BYTES {
            self.write_out(&mut pending)?;
        }
        Ok(())
    }

    /// Writes out the answers put so far.
    pub fn flush(&self) -> Result<()> {
        self.write_out(&mut self.pending.lock().unwrap_or_else(|e| e.into_inner()))
    }

    /// Appends the pending records. Another run can be appending to the
    /// same file, so it's locked while this run's go after whatever whole
    /// records are there; only a record cut short by a killed run is dropped.
    fn write_out(&self, pending: &mut Vec<u8>) -> Result<()> {
        let Some(path) = self.path.as_deref().filter(|_| !pending.is_empty()) else { return Ok(()) };
        if let Some(dir) = std::path::Path::new(path).parent() {
            fs::create_dir_all(dir)?;
        }
        refuse_link(path)?;
        let file = OpenOptions::new().read(true).write(true).create(true).truncate(false).open(path)?;
        file.lock().context("Couldn't save the cache")?;
        // The file indexed when the run began, or one made since: never
        // another put in its place.
        let now = file.metadata()?;
        let replaced = match &self.store {
            Some(Store::File(then)) => {
                then.metadata().map(|then| (then.dev(), then.ino()) != (now.dev(), now.ino()))?
            }
            _ => false,
        };
        if replaced || now.len() < self.end {
            bail!("{path} changed while judgelint ran; run it again");
        }
        let mut end = whole_records_end(&file, self.end, now.len()).with_context(|| format!("Couldn't save {path}"))?;
        if end != now.len() {
            file.set_len(end)?;
        }
        if end == 0 {
            file.write_all_at(HEADER, 0)?;
            end = HEADER.len() as u64;
        }
        file.write_all_at(pending, end).context("Couldn't save the cache")?;
        pending.clear();
        Ok(())
    }
}

/// Where the last whole record in the file ends, reading on from +from+, a
/// place one is known to end (or 0, before the header).
fn whole_records_end(file: &File, from: u64, length: u64) -> Result<u64> {
    if from == 0 {
        let mut header = [0u8; 8];
        if length < HEADER.len() as u64 || file.read_exact_at(&mut header, 0).is_err() {
            return Ok(0);
        }
        if &header != HEADER {
            bail!("it isn't a judgelint cache; delete it to start over");
        }
    }
    let mut at = from.max(HEADER.len() as u64);
    let mut record = [0u8; 36];
    while at + 36 <= length && file.read_exact_at(&mut record, at).is_ok() {
        let count = u64::from(u32::from_le_bytes(record[32..].try_into()?));
        let next = at + 36 + count * 8;
        if next > length || count >= 1 << COUNT_BITS {
            break;
        }
        at = next;
    }
    Ok(at)
}

/// A cache that's a link, or in a directory that's one, could write
/// anywhere it points.
fn refuse_link(path: &str) -> Result<()> {
    let path = std::path::Path::new(path);
    for link in [Some(path), path.parent()].into_iter().flatten().filter(|p| !p.as_os_str().is_empty()) {
        if fs::symlink_metadata(link).is_ok_and(|m| m.file_type().is_symlink()) {
            bail!("{} is a link; judgelint keeps its cache in a plain file and directory", link.display());
        }
    }
    Ok(())
}

/// The keys in a cache file, sorted, with the latest of any key stored twice,
/// and where its last whole record ends.
fn index(mut reader: impl Read + Seek, length: u64) -> Result<(Vec<(Key, u64)>, u64)> {
    if length == 0 {
        return Ok((Vec::new(), 0));
    }
    let mut header = [0u8; 8];
    if reader.read_exact(&mut header).is_err() || &header != HEADER {
        bail!("it isn't a judgelint cache; delete it to start over");
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
    use std::io::Write;

    use super::*;
    use crate::testing::TempDir;

    #[test]
    fn stores_reads_and_replaces() {
        let dir = TempDir::new();
        let path = dir.path("cache.bin");
        let path = path.as_str();
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
        assert_eq!(cache.get(&b).unwrap(), Some(vec![0.1, 0.2, 0.7]));
        cache.put(&b, &[0.5]).unwrap();
        cache.flush().unwrap();
        drop(cache);
        let cache = Cache::open(Some(path)).unwrap();
        assert_eq!(cache.get(&b).unwrap(), Some(vec![0.5]));
    }

    #[test]
    fn runs_that_share_a_cache_keep_each_others_answers() {
        let dir = TempDir::new();
        let path = dir.path("cache.bin");
        let (a, b, c) = (key("a", "s", "m"), key("b", "s", "m"), key("c", "s", "m"));
        let first = Cache::open(Some(&path)).unwrap();
        let second = Cache::open(Some(&path)).unwrap();
        first.put(&a, &[0.1]).unwrap();
        first.flush().unwrap();
        second.put(&b, &[0.2]).unwrap();
        second.flush().unwrap();
        let third = Cache::open(Some(&path)).unwrap();
        first.put(&c, &[0.3]).unwrap();
        first.flush().unwrap();
        drop((first, second, third));
        let cache = Cache::open(Some(&path)).unwrap();
        for (key, value) in [(a, 0.1), (b, 0.2), (c, 0.3)] {
            assert_eq!(cache.get(&key).unwrap(), Some(vec![value]));
        }
    }

    #[test]
    fn a_cache_in_memory_answers_and_keeps_nothing() {
        let dir = TempDir::new();
        let path = dir.path("cache.bin");
        let saved = Cache::open(Some(&path)).unwrap();
        saved.put(&key("q", "s", "m"), &[0.4]).unwrap();
        saved.flush().unwrap();
        let cache = Cache::in_memory(fs::read(&path).unwrap()).unwrap();
        assert_eq!(cache.get(&key("q", "s", "m")).unwrap(), Some(vec![0.4]));
        cache.put(&key("q2", "s", "m"), &[0.5]).unwrap();
        cache.flush().unwrap();
        assert_eq!(Cache::open(Some(&path)).unwrap().get(&key("q2", "s", "m")).unwrap(), None);
        assert!(Cache::in_memory(Vec::new()).unwrap().get(&key("q", "s", "m")).unwrap().is_none());
    }

    #[test]
    fn the_key_is_the_question_state_and_model() {
        let keys = [key("q", "s", "m"), key("q2", "s", "m"), key("q", "s2", "m"), key("q", "s", "m2")];
        for (i, a) in keys.iter().enumerate() {
            assert!(keys[i + 1..].iter().all(|b| a != b));
        }
        assert_eq!(key("q", "s", "m"), keys[0]);
    }

    #[test]
    fn misses_and_keys_that_start_alike() {
        let dir = TempDir::new();
        let path = dir.path("cache.bin");
        let alike = |last: u8| {
            let mut key = [7u8; 32];
            key[31] = last;
            key
        };
        let cache = Cache::open(Some(&path)).unwrap();
        assert_eq!(cache.get(&alike(1)).unwrap(), None, "nothing saved yet");
        for last in [1, 5, 9] {
            cache.put(&alike(last), &[f64::from(last)]).unwrap();
        }
        cache.flush().unwrap();
        drop(cache);
        let cache = Cache::open(Some(&path)).unwrap();
        for last in [1, 5, 9] {
            assert_eq!(cache.get(&alike(last)).unwrap(), Some(vec![f64::from(last)]));
        }
        assert_eq!(cache.get(&alike(3)).unwrap(), None);
        assert_eq!(cache.get(&key("q", "s", "m")).unwrap(), None);
    }

    #[test]
    fn the_latest_answer_wins_across_saves() {
        let dir = TempDir::new();
        let path = dir.path("cache.bin");
        let (a, b, c) = (key("a", "s", "m"), key("b", "s", "m"), key("c", "s", "m"));
        let cache = Cache::open(Some(&path)).unwrap();
        cache.put(&b, &[0.25]).unwrap();
        cache.put(&a, &[0.5]).unwrap();
        cache.put(&b, &[0.75]).unwrap();
        cache.flush().unwrap();
        // A saved cache can take more answers.
        cache.put(&c, &[1.0]).unwrap();
        cache.flush().unwrap();
        drop(cache);
        let cache = Cache::open(Some(&path)).unwrap();
        assert_eq!(cache.get(&a).unwrap(), Some(vec![0.5]));
        assert_eq!(cache.get(&b).unwrap(), Some(vec![0.75]));
        assert_eq!(cache.get(&c).unwrap(), Some(vec![1.0]));
    }

    #[test]
    fn many_answers_over_two_runs() {
        let dir = TempDir::new();
        let path = dir.path("cache.bin");
        let cache = Cache::open(Some(&path)).unwrap();
        for i in 0..300 {
            cache.put(&key(&i.to_string(), "s", "m"), &[f64::from(i)]).unwrap();
        }
        cache.flush().unwrap();
        drop(cache);
        let cache = Cache::open(Some(&path)).unwrap();
        // The second run replaces every tenth answer and adds 700.
        for i in (0..300).step_by(10).chain(300..1000) {
            cache.put(&key(&i.to_string(), "s", "m"), &[f64::from(i), 1.0]).unwrap();
        }
        cache.flush().unwrap();
        drop(cache);
        let cache = Cache::open(Some(&path)).unwrap();
        for i in 0..1000 {
            let expected = if i < 300 && i % 10 != 0 { vec![f64::from(i)] } else { vec![f64::from(i), 1.0] };
            assert_eq!(cache.get(&key(&i.to_string(), "s", "m")).unwrap(), Some(expected), "{i}");
        }
    }

    #[test]
    fn a_file_that_isnt_a_cache_is_an_error() {
        let dir = TempDir::new();
        let path = dir.write("cache.bin", "{not json");
        let error = Cache::open(Some(&path)).err().unwrap();
        assert!(format!("{error:#}").contains("delete it"), "{error:#}");
        assert_eq!(fs::read_to_string(&path).unwrap(), "{not json", "left as it was");

        // An empty file is an empty cache.
        let path = dir.write("empty.bin", "");
        let cache = Cache::open(Some(&path)).unwrap();
        cache.put(&key("q", "s", "m"), &[0.5]).unwrap();
        cache.flush().unwrap();
        drop(cache);
        assert_eq!(Cache::open(Some(&path)).unwrap().get(&key("q", "s", "m")).unwrap(), Some(vec![0.5]));
    }

    #[test]
    fn a_cache_that_is_a_link_is_an_error() {
        let dir = TempDir::new();
        let target = dir.write("elsewhere.bin", "");
        let path = dir.path("cache.bin");
        std::os::unix::fs::symlink(&target, &path).unwrap();
        assert!(Cache::open(Some(&path)).err().unwrap().to_string().contains("is a link"));
        let linked = dir.path("linked");
        std::os::unix::fs::symlink(dir.path(""), &linked).unwrap();
        assert!(Cache::open(Some(&format!("{linked}/cache.bin"))).err().unwrap().to_string().contains("is a link"));
    }
}
