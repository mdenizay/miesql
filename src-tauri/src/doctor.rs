//! `miesql --doctor` — a self-check that answers the questions a bug report about
//! credentials or storage always needs, without asking anyone to describe their setup.

use crate::storage;

pub fn run() -> i32 {
    println!("MieSQL {}", env!("CARGO_PKG_VERSION"));
    println!(
        "Platform: {} {}",
        std::env::consts::OS,
        std::env::consts::ARCH
    );

    let dir = storage::support_dir();
    println!("\nData directory: {}", dir.display());
    println!("  exists:   {}", dir.exists());
    println!("  writable: {}", probe_directory_write(&dir));

    println!("\nCredential store:");
    let account = "miesql-doctor-probe";
    match storage::save_password(account, "probe") {
        Ok(()) => {
            let read_back = storage::load_password(account);
            println!("  write: ok");
            println!(
                "  read:  {}",
                match read_back.as_deref() {
                    Some("probe") => "ok".to_string(),
                    Some(other) => format!("unexpected value {other:?}"),
                    None => "failed — the item was written but could not be read".to_string(),
                }
            );
            storage::delete_password(account);
            println!("  delete: ok");
            0
        }
        Err(error) => {
            println!("  write: FAILED");
            println!("  {}", error.message);
            if let Some(detail) = &error.detail {
                println!("  detail: {detail}");
            }
            println!(
                "\nOn macOS this is usually a code signature problem: the keychain refuses\n\
                 apps it cannot identify. Re-signing the bundle normally fixes it:\n\
                 \x20 codesign --force --deep --sign - /Applications/MieSQL.app"
            );
            1
        }
    }
}

fn probe_directory_write(dir: &std::path::Path) -> String {
    let probe = dir.join(".write-probe");
    match std::fs::write(&probe, b"probe") {
        Ok(()) => {
            let _ = std::fs::remove_file(&probe);
            "yes".to_string()
        }
        Err(error) => format!("no — {error}"),
    }
}
