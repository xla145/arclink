//! Deterministic test fixture, never registered as a production adapter.
use std::io::{Read, Write};
fn main() {
    let args: Vec<_> = std::env::args().collect();
    if args.iter().any(|s| s == "--version") {
        println!("abp-test-agent 1");
        return;
    }
    if args.iter().any(|s| s == "--noisy") {
        std::thread::spawn(|| loop {
            let _ = std::io::stdout().write_all(b"tick\n");
            let _ = std::io::stdout().flush();
            std::thread::sleep(std::time::Duration::from_millis(10));
        });
    }
    if args.iter().any(|s| s == "--flood") {
        let _ = std::io::stdout().write_all(&vec![b'x'; 6 * 1024 * 1024]);
        let _ = std::io::stdout().flush();
    }
    let mut bytes = [0u8; 8192];
    loop {
        let n = std::io::stdin().read(&mut bytes).unwrap();
        if n == 0 {
            break;
        }
        std::io::stdout().write_all(&bytes[..n]).unwrap();
        std::io::stdout().flush().unwrap();
        std::io::stderr().write_all(b"input received\n").unwrap();
        std::io::stderr().flush().unwrap();
    }
}
