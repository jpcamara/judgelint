//! Colors for a terminal. They're on when the stream is a terminal, unless
//! NO_COLOR is set or TERM is dumb. FORCE_COLOR turns them on anywhere, so
//! piped output can be colored too. With colors off, text passes through
//! unchanged.

use std::borrow::Cow;

pub const BOLD: &str = "1";
pub const DIM: &str = "2";
pub const RED: &str = "31";
pub const GREEN: &str = "32";
pub const YELLOW: &str = "33";
pub const CYAN: &str = "36";
pub const BOLD_RED: &str = "1;31";
pub const BOLD_GREEN: &str = "1;32";

#[derive(Clone, Copy)]
pub struct Paint {
    on: bool,
}

fn set(name: &str) -> bool {
    std::env::var_os(name).is_some_and(|v| !v.is_empty())
}

impl Paint {
    pub fn new(on: bool) -> Self {
        Paint { on }
    }

    /// For a stream that is or isn't a terminal.
    pub fn for_stream(tty: bool) -> Self {
        if set("NO_COLOR") || std::env::var_os("TERM").is_some_and(|t| t == "dumb") {
            return Paint::new(false);
        }
        if set("FORCE_COLOR") && std::env::var_os("FORCE_COLOR").is_some_and(|v| v != "0") {
            return Paint::new(true);
        }
        Paint::new(tty)
    }

    pub fn on(&self) -> bool {
        self.on
    }

    /// +text+ in the SGR style +code+, such as `paint::RED`.
    pub fn call(&self, text: &str, code: &str) -> String {
        if self.on { format!("\x1b[{code}m{text}\x1b[0m") } else { text.to_string() }
    }
}

/// +text+ with control characters escaped, for text from a file name, a
/// repository or an endpoint: a newline or an escape sequence in it could
/// otherwise forge a line of output. So could a CI command: GitHub Actions
/// reads one from a line that starts with `::` or holds `##[`, Azure
/// Pipelines from `##vso[` and TeamCity from `##teamcity[`. A leading `::`
/// gets a backslash, and so does each `#` after another.
pub fn clean(text: &str) -> Cow<'_, str> {
    let control = |c: char| c.is_control() && c != '\t';
    let command = |text: &str| text.trim_start().starts_with("::") || text.contains("##");
    if !text.chars().any(control) && !command(text) {
        return Cow::Borrowed(text);
    }
    let mut cleaned = String::with_capacity(text.len() + 8);
    for c in text.chars() {
        if control(c) {
            cleaned.extend(c.escape_default());
        } else {
            if c == '#' && cleaned.ends_with('#') {
                cleaned.push('\\');
            }
            cleaned.push(c);
        }
    }
    if cleaned.trim_start().starts_with("::") {
        cleaned.insert(cleaned.len() - cleaned.trim_start().len(), '\\');
    }
    Cow::Owned(cleaned)
}

#[cfg(test)]
mod tests {
    use super::clean;

    #[test]
    fn control_characters_and_workflow_commands_are_escaped() {
        assert_eq!(clean("app/a.rb\tok"), "app/a.rb\tok");
        assert_eq!(clean("a\n::error::forged\x1b[31m"), "a\\n::error::forged\\u{1b}[31m");
        assert_eq!(clean("::error::forged.rb"), "\\::error::forged.rb");
        assert_eq!(clean(" ::warning::x"), " \\::warning::x");
        assert_eq!(clean("bad ##[error]forged"), "bad #\\#[error]forged");
        assert_eq!(clean("##vso[task.uploadfile]/etc/passwd"), "#\\#vso[task.uploadfile]/etc/passwd");
        assert_eq!(clean("a ###teamcity["), "a #\\#\\#teamcity[");
        assert_eq!(clean("issue #12"), "issue #12");
        assert_eq!(clean("lib/a::b.rb"), "lib/a::b.rb");
    }
}
