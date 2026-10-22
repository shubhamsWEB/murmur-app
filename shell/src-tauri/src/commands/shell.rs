//! Running a command for a spoken request ("how much space is left on C", "what's my IP address", "zip the Reports
//! folder"), as the Mac's ShellCommand, in PowerShell on Windows. A command that only reads runs straight away;
//! anything else is shown to you first (agent.rs asks), and nothing is ever run as administrator.

use std::io::Read;
use std::time::{Duration, Instant};

/// Commands and programs that only read and report. Anything else (or one of these writing to a file) asks first.
const READ_ONLY: &[&str] = &[
    // PowerShell's readers (Get-* is checked apart) and the cmdlets that shape their output.
    "test-path", "test-connection", "resolve-path", "split-path", "join-path", "select-object", "select", "where-object",
    "where", "?", "sort-object", "sort", "measure-object", "measure", "group-object", "format-table", "ft", "format-list",
    "fl", "format-wide", "out-string", "convertto-json", "convertto-csv", "select-string", "sls", "foreach-object", "%",
    "write-output", "echo", "dir", "ls", "gci", "cat", "gc", "type", "pwd", "hostname", "whoami",
    // Windows' own programs that only report.
    "ipconfig", "systeminfo", "tasklist", "ping", "nslookup", "tracert", "pathping", "netstat", "driverquery", "ver",
    "where.exe", "findstr", "find", "tree", "wmic", "getmac", "route", "arp", "powercfg", "vol", "chcp", "date", "time",
    "quser", "query", "fsutil", "w32tm", "winver",
];

/// Of those, arguments that change something: `powercfg /change`, `route add`, `fsutil … set`, `netstat` is fine.
fn writes(program: &str, rest: &[&str]) -> bool {
    let first = rest.first().map(|w| w.to_lowercase()).unwrap_or_default();
    match program {
        "powercfg" => !["/list", "/l", "/query", "/q", "/a", "/availablesleepstates", "/getactivescheme", "/requests", "-list",
                         "-l", "-query", "-q", "-a", "-getactivescheme", "-requests"].contains(&first.as_str()),
        "route" => first != "print",
        "arp" => first != "-a" && first != "/a",
        "fsutil" => !["fsinfo", "volume", "8dot3name"].contains(&first.as_str())
            || rest.iter().any(|w| ["set", "dismount", "delete", "create"].contains(&w.to_lowercase().as_str())),
        "wmic" => rest.iter().any(|w| ["call", "set", "delete", "create"].contains(&w.to_lowercase().as_str())),
        "w32tm" => first != "/query" && first != "/tz",
        "date" | "time" => !rest.is_empty() && !["/t", "-t"].contains(&first.as_str()),
        "query" => false,
        _ => false,
    }
}

/// Get-* cmdlets that don't only read (Get-Credential asks for a password).
const GET_BUT_NOT_READ: &[&str] = &["get-credential"];

/// True when the command can run without asking: every part of its pipeline only reads, with nothing written to a
/// file and no second command, script block that runs code, or call operator.
pub fn is_read_only(command: &str) -> bool {
    let text = command.trim();
    if text.is_empty() || text.contains('\n') {
        return false;
    }
    // A second command (;, &&, ||), a redirection into a file, a subexpression or call operator, a script run.
    if text.contains(';') || text.contains("&&") || text.contains("||") || text.contains('>') || text.contains("$(")
        || text.contains('&') || text.contains('`') || text.starts_with('.') || text.contains("@(") {
        return false;
    }
    let lower = text.to_lowercase();
    // Cmdlets that change things, wherever they are (a -Command, a script block): asked.
    for word in ["invoke-", "iex", "start-process", "set-", "remove-", "new-", "add-", "clear-", "move-", "copy-",
                 "rename-", "stop-", "restart-", "out-file", "export-", "tee-", "-outfile", "-delete", "del ", "rm ",
                 "rmdir", "erase", "format-volume", "-encodedcommand", "-command", "[system.", "[io."] {
        if lower.contains(word) {
            return false;
        }
    }
    for segment in text.split('|') {
        let words: Vec<&str> = segment.split_whitespace().collect();
        let Some(program) = words.first().map(|w| w.to_lowercase()) else { return false };
        let program = program.trim_end_matches(".exe").to_string();
        let rest = &words[1..];
        if program.starts_with("get-") {
            if GET_BUT_NOT_READ.contains(&program.as_str()) {
                return false;
            }
            continue;
        }
        if program == "git" {
            let read = ["status", "log", "diff", "show", "branch", "remote", "rev-parse", "describe", "blame"];
            if !rest.first().is_some_and(|w| read.contains(&w.to_lowercase().as_str())) {
                return false;
            }
            continue;
        }
        if program == "netsh" {
            // "netsh wlan show interfaces", "netsh interface show interface": shows only.
            if !rest.iter().any(|w| w.eq_ignore_ascii_case("show")) {
                return false;
            }
            continue;
        }
        if !READ_ONLY.contains(&program.as_str()) && !READ_ONLY.contains(&format!("{program}.exe").as_str()) {
            return false;
        }
        if writes(&program, rest) {
            return false;
        }
    }
    true
}

/// Whether the command tries to run as administrator: Murmur never does.
pub fn uses_admin(command: &str) -> bool {
    let lower = command.to_lowercase();
    lower.contains("-verb runas") || lower.contains("-verb:runas") || lower.split(|c: char| !c.is_alphanumeric() && c != '-')
        .any(|w| w == "runas" || w == "sudo" || w == "gsudo")
}

#[cfg_attr(not(windows), allow(dead_code))]
pub struct Ran {
    pub status: Option<i32>,
    pub output: String,
    pub timed_out: bool,
}

/// Runs a command in PowerShell (Windows; `sh` elsewhere, for tests), in the home folder, with no window, and gives
/// what it printed (both streams, cut to `limit` characters).
#[cfg_attr(not(windows), allow(dead_code))]
pub fn run(command: &str, timeout: Duration, limit: usize) -> Ran {
    let mut process = if cfg!(windows) {
        let mut process = std::process::Command::new("powershell.exe");
        process.args(["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command",
                      &format!("[Console]::OutputEncoding=[Text.Encoding]::UTF8; $ProgressPreference='SilentlyContinue'; {command}")]);
        process
    } else {
        let mut process = std::process::Command::new("sh");
        process.args(["-c", command]);
        process
    };
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        process.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }
    if let Some(home) = std::env::var_os("USERPROFILE").or_else(|| std::env::var_os("HOME")) {
        process.current_dir(home);
    }
    process.stdin(std::process::Stdio::null()).stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::piped());
    let mut child = match process.spawn() {
        Ok(child) => child,
        Err(error) => return Ran { status: None, output: format!("Couldn't start PowerShell: {error}"), timed_out: false },
    };
    // Both streams read on their own threads, so a full pipe never stalls the command.
    let read = |stream: Option<Box<dyn Read + Send>>| {
        std::thread::spawn(move || {
            let mut bytes = Vec::new();
            if let Some(mut stream) = stream {
                let _ = stream.by_ref().take(256 * 1024).read_to_end(&mut bytes);
                let _ = std::io::copy(&mut stream, &mut std::io::sink());
            }
            bytes
        })
    };
    let out = read(child.stdout.take().map(|s| Box::new(s) as Box<dyn Read + Send>));
    let err = read(child.stderr.take().map(|s| Box::new(s) as Box<dyn Read + Send>));
    let started = Instant::now();
    let mut timed_out = false;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status.code(),
            Ok(None) if started.elapsed() > timeout => {
                timed_out = true;
                let _ = child.kill();
                break child.wait().ok().and_then(|s| s.code());
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(50)),
            Err(_) => break None,
        }
    };
    let mut output = String::from_utf8_lossy(&out.join().unwrap_or_default()).trim_end().to_string();
    let errors = String::from_utf8_lossy(&err.join().unwrap_or_default()).trim().to_string();
    if !errors.is_empty() {
        if !output.is_empty() {
            output.push('\n');
        }
        output.push_str(&errors);
    }
    if output.chars().count() > limit {
        output = format!("{}\n… (cut)", crate::ai::cut(&output, limit));
    }
    Ran { status, output: output.trim().to_string(), timed_out }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reading_runs_straight_away() {
        for command in ["Get-PSDrive C", "Get-ChildItem Downloads | Measure-Object -Property Length -Sum",
                        "ipconfig", "Get-NetIPAddress | Where-Object AddressFamily -eq IPv4 | Select-Object IPAddress",
                        "netsh wlan show interfaces", "git status", "systeminfo | findstr /C:\"Total Physical Memory\"",
                        "powercfg /a", "Get-CimInstance Win32_Battery | Select-Object EstimatedChargeRemaining"] {
            assert!(is_read_only(command), "{command}");
        }
    }

    #[test]
    fn anything_else_asks_first() {
        for command in ["Remove-Item Downloads\\old.zip", "Get-ChildItem | Remove-Item", "Compress-Archive Reports Reports.zip",
                        "Get-Process > list.txt", "ipconfig /release; ipconfig /renew", "Stop-Process -Name chrome",
                        "powercfg /change monitor-timeout-ac 5", "git push", "Invoke-WebRequest x -OutFile y",
                        "& 'C:\\x.exe'", "route add 10.0.0.0 mask 255.0.0.0 10.0.0.1", "Get-Credential", "", "netsh wlan disconnect"] {
            assert!(!is_read_only(command), "{command}");
        }
    }

    #[test]
    fn never_as_administrator() {
        assert!(uses_admin("Start-Process powershell -Verb RunAs"));
        assert!(uses_admin("sudo winget upgrade --all"));
        assert!(!uses_admin("Get-ChildItem C:\\Users\\runasmith"));
    }

    #[cfg(unix)]
    #[test]
    fn runs_and_gathers_both_streams() {
        let ran = run("echo hi; echo oops >&2; exit 3", Duration::from_secs(5), 100);
        assert_eq!(ran.status, Some(3));
        assert_eq!(ran.output, "hi\noops");
        let slow = run("sleep 5", Duration::from_millis(200), 100);
        assert!(slow.timed_out);
    }
}
