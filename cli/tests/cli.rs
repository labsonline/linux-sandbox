// SPDX-License-Identifier: GPL-3.0

use assert_cmd::prelude::*;
use assert_fs::prelude::*;
use assert_fs::NamedTempFile;
use predicates::str;
use std::error;
use std::process::Command;

#[test]
fn file_doesnt_exist() -> Result<(), Box<dyn error::Error>> {
    let file = NamedTempFile::new("sample.txt")?;
    file.write_str("A test\nActual content\nMore content\nAnother test")?;

    let mut cmd = Command::cargo_bin("cli")?;
    cmd.arg("test").arg(file.path());
    cmd.assert()
        .success()
        .stdout(str::contains("A test\nAnother test"));

    Ok(())
}
