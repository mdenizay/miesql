//! SSH tunnelling.
//!
//! The happy path needs a reachable SSH server, so it is covered by the failure side here
//! and left to real use otherwise: what these check is that a tunnel which cannot be built
//! says why instead of hanging, and that a password with shell metacharacters in it cannot
//! turn into a command.

use miesql_lib::models::{ConnectionProfile, DatabaseKind};
use miesql_lib::ssh::SshTunnel;

fn tunnelled_profile(ssh_host: &str, ssh_port: u16) -> ConnectionProfile {
    let mut profile = ConnectionProfile::new(DatabaseKind::Postgres);
    profile.ssh_enabled = true;
    profile.ssh_host = ssh_host.into();
    profile.ssh_port = ssh_port;
    profile.ssh_username = "nobody".into();
    profile.connect_timeout_seconds = 5;
    profile
}

#[tokio::test(flavor = "multi_thread")]
async fn an_unreachable_ssh_host_fails_quickly_and_says_why() {
    // Port 1 has nothing listening, so ssh refuses immediately.
    let profile = tunnelled_profile("127.0.0.1", 1);
    let started = std::time::Instant::now();

    let error = SshTunnel::open(&profile, None, "127.0.0.1", 5432)
        .await
        .expect_err("a tunnel to nowhere should not succeed");

    // The point is that it returns at all: a forward that silently waits is the failure
    // mode worth guarding against.
    assert!(
        started.elapsed() < std::time::Duration::from_secs(20),
        "took {:?}",
        started.elapsed()
    );
    let text = format!("{} {}", error.message, error.detail.unwrap_or_default());
    assert!(
        text.to_lowercase().contains("refused")
            || text.to_lowercase().contains("closed")
            || text.to_lowercase().contains("did not open"),
        "unhelpful error: {text}"
    );
}

// Checked with pgrep, which Windows has no equivalent of worth shimming. The behaviour it
// guards — kill_on_drop plus an explicit start_kill — is not platform-specific, so covering
// it on Unix covers it.
#[cfg(unix)]
#[tokio::test(flavor = "multi_thread")]
async fn the_tunnel_does_not_leave_a_process_behind_when_it_fails() {
    let profile = tunnelled_profile("127.0.0.1", 1);
    let _ = SshTunnel::open(&profile, None, "127.0.0.1", 5432).await;

    // Give the child a moment to be reaped, then check nothing of ours is still forwarding.
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
    let output = std::process::Command::new("pgrep")
        .args(["-f", "ssh -N -T .*127.0.0.1:5432"])
        .output()
        .expect("pgrep");
    assert!(
        String::from_utf8_lossy(&output.stdout).trim().is_empty(),
        "an ssh process survived a failed tunnel"
    );
}

#[cfg(unix)]
#[test]
fn a_password_with_metacharacters_cannot_become_a_command() {
    // If this were interpolated naively, the backtick and semicolon would run.
    let nasty = "p'a$s`whoami`;rm -rf /\"x";
    let path = miesql_lib::ssh::write_askpass_helper(nasty).expect("helper");
    let script = std::fs::read_to_string(&path).expect("read helper");

    let output = std::process::Command::new("sh")
        .arg(&path)
        .output()
        .expect("run helper");
    let printed = String::from_utf8_lossy(&output.stdout);
    assert_eq!(
        printed.trim_end_matches('\n'),
        nasty,
        "script was: {script}"
    );

    // Readable only by its owner, since it holds a password until the tunnel is up.
    use std::os::unix::fs::PermissionsExt;
    let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o700);

    std::fs::remove_file(path).ok();
}
