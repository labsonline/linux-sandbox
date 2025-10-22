// SPDX-License-Identifier: GPL-3.0

use anyhow::{Context, Result};
use clap::Parser;
use cli::find_matches;
use std::{fs, io, path};

/// Search for a pattern in a file and display the lines that contain it.
#[derive(Parser)]
struct Cli {
    /// The pattern to look for.
    pattern: String,
    /// The path to the file to read.
    path: path::PathBuf,
}

fn main() -> Result<()> {
    let args = Cli::parse();
    let content = fs::read_to_string(&args.path)
        .with_context(|| format!("could not read file `{}`", args.path.display()))?;

    find_matches(&content, &args.pattern, &mut io::stdout());
    Ok(())
}
