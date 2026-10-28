//! Stores each answer under a hash of everything that produced it: the state
//! the model saw (path and numbered contents), the question asked of it, and
//! the model. Changing any of them is a miss. Safe to share across threads.
//!
//! The file is a log: a header, then a record per answer, its 32-byte key,
//! how many probabilities it has (u32), and each as an f64, little-endian.
//! Opening it indexes the keys and leaves the probabilities on disk until
//! they're asked for. New answers are appended, and a later record replaces
//! an earlier one with the same key. A record cut short by a killed run is
//! dropped before the next append. A file that isn't a cache is an error,
//! never overwritten.

use std::fs::{self, File, OpenOptions};
use std::io::{BufReader, BufWriter, Read, Write};
use std::os::unix::fs::FileExt;
use std::sync::Mutex;

use anyhow::{Context, Result, bail};
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
    /// Where the last whole record ends, or 0 when the file is new or empty.
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
    if length == 0 {
        return Ok((Vec::new(), 0));
    }
    let mut reader = BufReader::with_capacity(1 << 20, file);
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
}
