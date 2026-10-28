//! Colors for a terminal. They're on when the stream is a terminal, unless
//! NO_COLOR is set or TERM is dumb. FORCE_COLOR turns them on anywhere, so
//! piped output can be colored too. With colors off, text passes through
//! unchanged.

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
