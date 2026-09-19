//! SSH tunnelling, by driving the system `ssh` client.
//!
//! The obvious alternative was a pure-Rust SSH library, and it was tried first: every
//! version of russh currently fails to resolve, because a transitive dependency is no
//! longer available on crates.io. The remaining option, libssh2 bindings, would have put
//! OpenSSL back into a build that was deliberately moved to rustls.
//!
//! Shelling out turns out to be the better answer anyway. It inherits the user's existing
//! setup — `~/.ssh/config`, the agent, hardware keys, jump hosts, ProxyCommand,
//! known_hosts — so host key verification is OpenSSH's, not a reimplementation of it, and
//! a key that already works in a terminal works here without being described again.
//!
//! The cost is a dependency on an `ssh` binary. macOS and Linux always have one, Windows
//! has shipped OpenSSH since Windows 10, and a missing one is reported plainly.

use crate::error::{DbError, DbResult};
use crate::models::ConnectionProfile;
use std::net::TcpListener;
use std::process::Stdio;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::{Child, Command};

#[derive(Debug)]
pub struct SshTunnel {
    pub local_port: u16,
    child: Child,
    /// Deleted when the tunnel closes; it holds the password while ssh asks for it.
    askpass: Option<std::path::PathBuf>,
}

impl SshTunnel {
    /// Opens a local forward to `remote_host:remote_port` and returns the local port the
    /// driver should connect to instead.
    pub async fn open(
        profile: &ConnectionProfile,
        ssh_password: Option<&str>,
        remote_host: &str,
        remote_port: u16,
    ) -> DbResult<Self> {
        if which_ssh().is_none() {
            return Err(
                DbError::new("No ssh client was found on this computer.").with_detail(
                    "MieSQL tunnels through the system ssh command. macOS and Linux include \
                     one; on Windows, install the OpenSSH Client from Optional Features.",
                ),
            );
        }

        let local_port = free_local_port()?;
        let mut command = Command::new("ssh");
        command
            .arg("-N") // no remote command, just the forward
            .arg("-T") // no pseudo-terminal
            .arg("-o")
            .arg("ExitOnForwardFailure=yes") // fail loudly if the port is taken
            .arg("-o")
            .arg("ServerAliveInterval=30")
            .arg("-o")
            .arg(format!(
                "ConnectTimeout={}",
                profile.connect_timeout_seconds.max(1)
            ))
            .arg("-L")
            .arg(format!(
                "127.0.0.1:{local_port}:{remote_host}:{remote_port}"
            ))
            .arg("-p")
            .arg(profile.ssh_port.to_string());

        if !profile.ssh_key_path.is_empty() {
            command.arg("-i").arg(&profile.ssh_key_path);
            // With an explicit key, do not silently fall back to another method.
            command.arg("-o").arg("IdentitiesOnly=yes");
        }

        let target = if profile.ssh_username.is_empty() {
            profile.ssh_host.clone()
        } else {
            format!("{}@{}", profile.ssh_username, profile.ssh_host)
        };
        command.arg(target);

        // A password needs to reach ssh without a terminal. SSH_ASKPASS is the supported
        // way; the helper lives in a file only this user can read and is deleted as soon
        // as the tunnel is torn down.
        let askpass = match ssh_password.filter(|p| !p.is_empty()) {
            Some(password) => {
                let path = write_askpass_helper(password)?;
                command
                    .env("SSH_ASKPASS", &path)
                    .env("SSH_ASKPASS_REQUIRE", "force")
                    // Older clients only consult SSH_ASKPASS when they believe there is a
                    // display; harmless to set and it costs nothing when there is not.
                    .env("DISPLAY", ":0");
                Some(path)
            }
            None => {
                // No password to offer, so never sit waiting for a prompt nobody can see.
                command.arg("-o").arg("BatchMode=yes");
                None
            }
        };

        command
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .kill_on_drop(true);

        let mut child = command
            .spawn()
            .map_err(|e| DbError::new(format!("Could not start ssh: {e}")))?;

        // ssh prints nothing on success, so readiness is "the forwarded port accepts a
        // connection". Polling that beats sleeping an arbitrary amount.
        let stderr = child.stderr.take();
        let deadline = std::time::Instant::now()
            + std::time::Duration::from_secs(profile.connect_timeout_seconds.max(5));

        loop {
            if tokio::net::TcpStream::connect(("127.0.0.1", local_port))
                .await
                .is_ok()
            {
                return Ok(Self {
                    local_port,
                    child,
                    askpass,
                });
            }

            if let Ok(Some(status)) = child.try_wait() {
                let detail = match stderr {
                    Some(stream) => collect_stderr(stream).await,
                    None => String::new(),
                };
                cleanup(&askpass);
                return Err(DbError::new(format!(
                    "The SSH tunnel to {} closed immediately ({status}).",
                    profile.ssh_host
                ))
                .with_detail(detail));
            }

            if std::time::Instant::now() > deadline {
                let _ = child.kill().await;
                cleanup(&askpass);
                return Err(DbError::new(format!(
                    "The SSH tunnel to {} did not open within {} seconds.",
                    profile.ssh_host, profile.connect_timeout_seconds
                )));
            }

            tokio::time::sleep(std::time::Duration::from_millis(120)).await;
        }
    }
}

impl Drop for SshTunnel {
    fn drop(&mut self) {
        // kill_on_drop handles the process; the helper holding the password does not clean
        // itself up.
        let _ = self.child.start_kill();
        cleanup(&self.askpass);
    }
}

fn cleanup(askpass: &Option<std::path::PathBuf>) {
    if let Some(path) = askpass {
        let _ = std::fs::remove_file(path);
    }
}

async fn collect_stderr(stream: tokio::process::ChildStderr) -> String {
    let mut lines = BufReader::new(stream).lines();
    let mut collected = Vec::new();
    while let Ok(Some(line)) = lines.next_line().await {
        collected.push(line);
        if collected.len() >= 8 {
            break;
        }
    }
    collected.join("\n")
}

fn which_ssh() -> Option<std::path::PathBuf> {
    let name = if cfg!(windows) { "ssh.exe" } else { "ssh" };
    std::env::var_os("PATH").and_then(|paths| {
        std::env::split_paths(&paths)
            .map(|dir| dir.join(name))
            .find(|candidate| candidate.is_file())
    })
}

/// Binds port 0 to let the OS pick a free port, then releases it. There is a small window
/// before ssh claims it, which is why the command uses ExitOnForwardFailure.
fn free_local_port() -> DbResult<u16> {
    let listener = TcpListener::bind("127.0.0.1:0")
        .map_err(|e| DbError::new(format!("Could not reserve a local port: {e}")))?;
    let port = listener
        .local_addr()
        .map_err(|e| DbError::new(format!("Could not read the local port: {e}")))?
        .port();
    drop(listener);
    Ok(port)
}

#[cfg(unix)]
/// Public so the tests can check the escaping; it writes only to a private temp file.
pub fn write_askpass_helper(password: &str) -> DbResult<std::path::PathBuf> {
    use std::io::Write;
    use std::os::unix::fs::PermissionsExt;

    let path = std::env::temp_dir().join(format!("miesql-askpass-{}", uuid::Uuid::new_v4()));
    let mut file = std::fs::File::create(&path)
        .map_err(|e| DbError::new(format!("Could not prepare the SSH password helper: {e}")))?;
    // Single-quoted with any embedded quote escaped, so a password containing shell
    // metacharacters cannot turn into a command.
    let escaped = password.replace('\'', "'\\''");
    writeln!(file, "#!/bin/sh\nprintf '%s\\n' '{escaped}'")
        .map_err(|e| DbError::new(format!("Could not write the SSH password helper: {e}")))?;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700))
        .map_err(|e| DbError::new(format!("Could not secure the SSH password helper: {e}")))?;
    Ok(path)
}

#[cfg(windows)]
fn write_askpass_helper(_password: &str) -> DbResult<std::path::PathBuf> {
    // Windows ssh.exe does not honour SSH_ASKPASS, so there is nowhere to put the
    // password. Saying so beats a tunnel that hangs on an invisible prompt.
    Err(
        DbError::new("SSH password authentication is not supported on Windows.").with_detail(
            "Use a private key instead, or add the key to ssh-agent. Both work here because \
         MieSQL tunnels through the system ssh client.",
        ),
    )
}
