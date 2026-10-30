//! judgelint checks code against conventions written in plain English. Each
//! rule is a question that a System One decision model answers with a
//! probability.

mod cache;
mod changes;
mod cli;
mod client;
mod config;
mod git;
mod glob;
mod paint;
mod project;
mod protocol;
mod providers;
mod question;
mod reporter;
mod rule;
mod runner;
mod source;
mod spec;
#[cfg(test)]
mod testing;
mod usage;
mod verdict;

/// Finding and reading files is mostly the file system's work, and past four
/// threads its locks cost more than the threads gain.
pub const FILE_THREADS: usize = 4;

fn main() {
    if std::env::var_os("RAYON_NUM_THREADS").is_none() {
        let threads = std::thread::available_parallelism().map_or(1, |n| n.get()).min(FILE_THREADS);
        let _ = rayon::ThreadPoolBuilder::new().num_threads(threads).build_global();
    }
    std::process::exit(cli::main());
}
