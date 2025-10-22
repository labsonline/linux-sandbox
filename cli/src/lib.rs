// SPDX-License-Identifier: GPL-3.0

use std::io;

pub fn find_matches(content: &str, pattern: &str, mut writer: impl io::Write) {
    for line in content.lines() {
        if line.contains(&pattern) {
            if let Err(e) = writeln!(writer, "{line}") {
                eprintln!("{e}");
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn find_a_match() {
        let mut result = Vec::new();
        find_matches("lorem ipsum\ndolor sit amet", "lorem", &mut result);
        assert_eq!(result, b"lorem ipsum\n");
    }
}
