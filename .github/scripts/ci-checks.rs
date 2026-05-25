use std::collections::HashMap;
use std::env;
use std::fs;
use std::process::{Command, Stdio};

#[derive(Debug, Clone, Copy)]
struct PhpVersion {
    major: u32,
    minor: u32,
    patch: u32,
}

impl PhpVersion {
    fn parse(value: &str) -> Result<Self, String> {
        let trimmed = value.trim();
        let mut parts = Vec::new();
        let mut current = String::new();

        for ch in trimmed.chars() {
            if ch.is_ascii_digit() {
                current.push(ch);
                continue;
            }

            if ch == '.' {
                if current.is_empty() {
                    break;
                }
                parts.push(current.parse::<u32>().map_err(|err| err.to_string())?);
                current.clear();
                continue;
            }

            break;
        }

        if !current.is_empty() {
            parts.push(current.parse::<u32>().map_err(|err| err.to_string())?);
        }

        if parts.len() < 2 {
            return Err(format!("Could not parse PHP version from {trimmed:?}"));
        }

        Ok(Self {
            major: parts[0],
            minor: parts[1],
            patch: *parts.get(2).unwrap_or(&0),
        })
    }

    fn at_least(self, major: u32, minor: u32) -> bool {
        (self.major, self.minor) >= (major, minor)
    }

    fn before(self, major: u32, minor: u32) -> bool {
        (self.major, self.minor) < (major, minor)
    }
}

fn main() {
    if let Err(err) = run_main() {
        eprintln!("{err}");
        std::process::exit(1);
    }
}

fn run_main() -> Result<(), String> {
    let mut args = env::args().skip(1);
    let command = args.next().ok_or_else(usage)?;
    let args: Vec<String> = args.collect();

    match command.as_str() {
        "env-options" => check_env_options(&args),
        "version-list" => check_version_list(&args),
        "installed-tools" => check_installed_tools(&args),
        _ => Err(usage()),
    }
}

fn usage() -> String {
    "Usage:\n  ci-checks env-options <mise-env-file>\n  ci-checks version-list <source|static> <versions-file> <expected-version>\n  ci-checks installed-tools --mode <source|static> [--require-pecl]".to_string()
}

fn check_env_options(args: &[String]) -> Result<(), String> {
    if args.len() != 1 {
        return Err(usage());
    }

    let expected = HashMap::from([
        ("PHP_SKIP_DEPS", "1"),
        ("PHP_VERBOSE", "1"),
        ("PHP_PREBUILT_STATIC", "1"),
        ("PHP_PREBUILT_STATIC_FLAVOR", "minimal"),
        ("PHP_CONFIGURE_OPTIONS", "--disable-all"),
        ("PHP_EXTRA_CONFIGURE_OPTIONS", "--enable-option-checking=fatal"),
        ("PHP_DEPS_PROFILE", "full"),
        ("PHP_INSTALL_OPTIONAL_DEPS", "1"),
        ("PHP_PECL_EXTENSIONS", "redis,xdebug"),
        ("PHP_PIE_EXTENSIONS", "amphp/ext-uv"),
    ]);

    let content = fs::read_to_string(&args[0])
        .map_err(|err| format!("Failed to read {}: {err}", args[0]))?;
    let mut values = HashMap::new();

    for line in content.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }

        let Some((key, value)) = line.split_once('=') else {
            continue;
        };

        values.insert(key.trim().to_string(), strip_env_quotes(value.trim()).to_string());
    }

    let mut failures = Vec::new();
    for (key, expected_value) in expected {
        let actual = values.get(key).map(String::as_str);
        if actual != Some(expected_value) {
            failures.push(format!(
                "{key}: expected {expected_value:?}, got {:?}",
                actual
            ));
        }
    }

    if !failures.is_empty() {
        return Err(failures.join("\n"));
    }

    println!("env._.php options were exported correctly");
    Ok(())
}

fn strip_env_quotes(value: &str) -> &str {
    let bytes = value.as_bytes();
    if bytes.len() >= 2 {
        let first = bytes[0];
        let last = bytes[bytes.len() - 1];
        if (first == b'\'' && last == b'\'') || (first == b'\"' && last == b'\"') {
            return &value[1..value.len() - 1];
        }
    }
    value
}

fn check_version_list(args: &[String]) -> Result<(), String> {
    if args.len() != 3 {
        return Err(usage());
    }

    let kind = args[0].as_str();
    if kind != "source" && kind != "static" {
        return Err("version-list kind must be either 'source' or 'static'".to_string());
    }

    let file = &args[1];
    let expected = &args[2];
    let content = fs::read_to_string(file).map_err(|err| format!("Failed to read {file}: {err}"))?;
    let versions: Vec<&str> = content
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .collect();

    if versions.is_empty() {
        return Err(format!("No {kind} versions were returned"));
    }

    if !versions.iter().any(|version| version == expected) {
        return Err(format!("Expected PHP {expected} in {kind} version list"));
    }

    println!("{kind} version list contains {} versions", versions.len());
    Ok(())
}

fn check_installed_tools(args: &[String]) -> Result<(), String> {
    let mut mode: Option<String> = None;
    let mut require_pecl = false;
    let mut index = 0;

    while index < args.len() {
        match args[index].as_str() {
            "--mode" => {
                let value = args
                    .get(index + 1)
                    .ok_or_else(|| "Missing value for --mode".to_string())?;
                if value != "source" && value != "static" {
                    return Err("--mode must be either 'source' or 'static'".to_string());
                }
                mode = Some(value.clone());
                index += 2;
            }
            "--require-pecl" => {
                require_pecl = true;
                index += 1;
            }
            other => return Err(format!("Unknown argument: {other}")),
        }
    }

    let mode = mode.ok_or_else(usage)?;
    let runner_os = env::var("RUNNER_OS").unwrap_or_default();

    mise_exec(&["php", "--version"], false)?;

    let php_version_raw = mise_exec(&["php", "-r", "echo PHP_VERSION;"], true)?;
    let php_version_text = php_version_raw.trim();
    let php_version = PhpVersion::parse(php_version_text)?;
    println!(
        "Detected PHP {} ({}.{}.{})",
        php_version_text, php_version.major, php_version.minor, php_version.patch
    );

    mise_exec(&["composer", "--version"], false)?;

    if php_version.at_least(8, 1) {
        require_php_extension("iconv", "PIE requires iconv at runtime")?;
        mise_exec(&["pie", "--version"], false)?;
    } else {
        println!(
            "Skipping PIE check for PHP {}: PIE requires PHP 8.1 or newer.",
            php_version_text
        );
    }

    if mode == "static" {
        if require_pecl {
            return Err(
                "PECL was required, but PECL is intentionally skipped for prebuilt static PHP installs."
                    .to_string(),
            );
        }
        println!("Skipping PECL check for prebuilt static PHP: static builds ship with a fixed extension set.");
        return Ok(());
    }

    if !php_version.before(8, 5) {
        if require_pecl {
            return Err(format!(
                "PECL was required, but PHP {} is not PECL-capable in this plugin.",
                php_version_text
            ));
        }
        println!(
            "Skipping PECL check for PHP {}: PECL is not available from PHP 8.5 onward.",
            php_version_text
        );
        return Ok(());
    }

    if runner_os == "Windows" {
        if require_pecl {
            return Err(
                "PECL was required, but the Windows installer path does not provision PEAR/PECL."
                    .to_string(),
            );
        }
        println!("Skipping PECL check on Windows: the Windows installer path does not provision PEAR/PECL.");
        return Ok(());
    }

    mise_exec(&["pecl", "version"], false)?;
    Ok(())
}

fn require_php_extension(extension: &str, reason: &str) -> Result<(), String> {
    let modules = mise_exec(&["php", "-m"], true)?;
    let found = modules
        .lines()
        .map(str::trim)
        .any(|line| line.eq_ignore_ascii_case(extension));

    if !found {
        return Err(format!(
            "PHP extension {extension:?} is required: {reason}. Installed modules did not include it."
        ));
    }

    println!("PHP extension {extension} is available");
    Ok(())
}

fn mise_exec(args: &[&str], capture: bool) -> Result<String, String> {
    let mut command = vec!["exec", "--"];
    command.extend_from_slice(args);
    run_command("mise", &command, capture)
}

fn run_command(program: &str, args: &[&str], capture: bool) -> Result<String, String> {
    print_command(program, args);

    if capture {
        let output = Command::new(program)
            .args(args)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output()
            .map_err(|err| format!("Failed to run {program}: {err}"))?;

        let stdout = String::from_utf8_lossy(&output.stdout).to_string();
        let stderr = String::from_utf8_lossy(&output.stderr).to_string();

        if !stdout.is_empty() {
            print!("{stdout}");
            if !stdout.ends_with('\n') {
                println!();
            }
        }
        if !stderr.is_empty() {
            eprint!("{stderr}");
            if !stderr.ends_with('\n') {
                eprintln!();
            }
        }

        if !output.status.success() {
            return Err(format!(
                "Command failed with exit code {}: {} {}",
                output.status.code().unwrap_or(-1),
                program,
                args.join(" ")
            ));
        }

        return Ok(stdout);
    }

    let status = Command::new(program)
        .args(args)
        .status()
        .map_err(|err| format!("Failed to run {program}: {err}"))?;

    if !status.success() {
        return Err(format!(
            "Command failed with exit code {}: {} {}",
            status.code().unwrap_or(-1),
            program,
            args.join(" ")
        ));
    }

    Ok(String::new())
}

fn print_command(program: &str, args: &[&str]) {
    println!("+ {} {}", program, args.join(" "));
}
