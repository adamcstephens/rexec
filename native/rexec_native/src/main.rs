use std::env;
use std::io::{self, Read, Write};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread;

use nix::sys::signal::{self, Signal};
use nix::unistd::Pid;

// Protocol tags: Rust -> Elixir
const TAG_PID: u8 = 0x00;
const TAG_STDOUT: u8 = 0x01;
const TAG_STDERR: u8 = 0x02;
const TAG_EXIT: u8 = 0x03;
const TAG_SIGNAL: u8 = 0x04;

// Protocol tags: Elixir -> Rust
const CMD_STDIN: u8 = 0x01;
const CMD_EOF: u8 = 0x02;
const CMD_KILL: u8 = 0x03;
const CMD_KILL_GROUP: u8 = 0x04;

fn send_packet(writer: &Mutex<impl Write>, tag: u8, data: &[u8]) {
    let mut w = writer.lock().unwrap();
    let len = (1 + data.len()) as u32;
    let _ = w.write_all(&len.to_be_bytes());
    let _ = w.write_all(&[tag]);
    let _ = w.write_all(data);
    let _ = w.flush();
}

fn read_packet(reader: &mut impl Read) -> io::Result<Vec<u8>> {
    let mut len_buf = [0u8; 4];
    reader.read_exact(&mut len_buf)?;
    let len = u32::from_be_bytes(len_buf) as usize;
    let mut buf = vec![0u8; len];
    reader.read_exact(&mut buf)?;
    Ok(buf)
}

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    if args.is_empty() {
        eprintln!("usage: rexec_native <command> [args...]");
        std::process::exit(1);
    }

    let mut cmd = Command::new(&args[0]);
    cmd.args(&args[1..])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    // Make child a process group leader so we can kill the whole group
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        cmd.process_group(0);
    }

    let mut child = cmd.spawn().unwrap_or_else(|e| {
        eprintln!("failed to spawn: {e}");
        std::process::exit(1);
    });

    let child_pid = child.id();
    let stdout_writer = Arc::new(Mutex::new(io::stdout()));

    // Send child PID
    send_packet(&stdout_writer, TAG_PID, &child_pid.to_be_bytes());

    // Take ownership of child I/O handles
    let child_stdout = child.stdout.take().unwrap();
    let child_stderr = child.stderr.take().unwrap();
    let child_stdin = child.stdin.take().unwrap();
    let child_stdin = Arc::new(Mutex::new(Some(child_stdin)));

    // Stdout reader thread
    let w = Arc::clone(&stdout_writer);
    let stdout_thread = thread::spawn(move || {
        let mut reader = io::BufReader::new(child_stdout);
        let mut buf = [0u8; 65536];
        loop {
            match reader.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => send_packet(&w, TAG_STDOUT, &buf[..n]),
                Err(_) => break,
            }
        }
    });

    // Stderr reader thread
    let w = Arc::clone(&stdout_writer);
    let stderr_thread = thread::spawn(move || {
        let mut reader = io::BufReader::new(child_stderr);
        let mut buf = [0u8; 65536];
        loop {
            match reader.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => send_packet(&w, TAG_STDERR, &buf[..n]),
                Err(_) => break,
            }
        }
    });

    // Stdin command reader thread
    let stdin_handle = Arc::clone(&child_stdin);
    let stdin_thread = thread::spawn(move || {
        let mut reader = io::stdin();
        loop {
            match read_packet(&mut reader) {
                Ok(packet) if packet.is_empty() => break,
                Ok(packet) => {
                    let tag = packet[0];
                    let data = &packet[1..];
                    match tag {
                        CMD_STDIN => {
                            if let Some(ref mut stdin) = *stdin_handle.lock().unwrap() {
                                let _ = stdin.write_all(data);
                                let _ = stdin.flush();
                            }
                        }
                        CMD_EOF => {
                            // Drop stdin to close it
                            *stdin_handle.lock().unwrap() = None;
                        }
                        CMD_KILL => {
                            if data.len() >= 4 {
                                let sig_num = i32::from_be_bytes([data[0], data[1], data[2], data[3]]);
                                if let Ok(sig) = Signal::try_from(sig_num) {
                                    let _ = signal::kill(Pid::from_raw(child_pid as i32), sig);
                                }
                            }
                        }
                        CMD_KILL_GROUP => {
                            if data.len() >= 4 {
                                let sig_num = i32::from_be_bytes([data[0], data[1], data[2], data[3]]);
                                if let Ok(sig) = Signal::try_from(sig_num) {
                                    // Negative PID sends signal to entire process group
                                    let _ = signal::kill(Pid::from_raw(-(child_pid as i32)), sig);
                                }
                            }
                        }
                        _ => {}
                    }
                }
                Err(_) => break,
            }
        }
    });

    // Wait for child to exit
    let status = child.wait().unwrap();

    // Wait for I/O threads to finish
    let _ = stdout_thread.join();
    let _ = stderr_thread.join();

    // Send exit status
    #[cfg(unix)]
    {
        use std::os::unix::process::ExitStatusExt;
        if let Some(signal) = status.signal() {
            send_packet(&stdout_writer, TAG_SIGNAL, &[signal as u8]);
        } else {
            let code = status.code().unwrap_or(1) as i32;
            send_packet(&stdout_writer, TAG_EXIT, &code.to_be_bytes());
        }
    }

    #[cfg(not(unix))]
    {
        let code = status.code().unwrap_or(1) as i32;
        send_packet(&stdout_writer, TAG_EXIT, &code.to_be_bytes());
    }

    // Don't wait for stdin thread — it'll die when we exit
    drop(stdin_thread);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    // --- Unit tests for packet protocol ---

    #[test]
    fn send_packet_encodes_tag_and_data() {
        let buf: Arc<Mutex<Vec<u8>>> = Arc::new(Mutex::new(Vec::new()));
        send_packet(&buf, TAG_STDOUT, b"hello");

        let output = buf.lock().unwrap();
        // length = 1 (tag) + 5 (data) = 6
        assert_eq!(&output[0..4], &6u32.to_be_bytes());
        assert_eq!(output[4], TAG_STDOUT);
        assert_eq!(&output[5..], b"hello");
    }

    #[test]
    fn send_packet_empty_data() {
        let buf: Arc<Mutex<Vec<u8>>> = Arc::new(Mutex::new(Vec::new()));
        send_packet(&buf, TAG_PID, &[]);

        let output = buf.lock().unwrap();
        // length = 1 (tag only)
        assert_eq!(&output[0..4], &1u32.to_be_bytes());
        assert_eq!(output[4], TAG_PID);
        assert_eq!(output.len(), 5);
    }

    #[test]
    fn read_packet_decodes_correctly() {
        let mut data = Vec::new();
        // Write a packet: length=3, payload=[0x01, 0xAA, 0xBB]
        data.extend_from_slice(&3u32.to_be_bytes());
        data.extend_from_slice(&[0x01, 0xAA, 0xBB]);

        let mut cursor = Cursor::new(data);
        let packet = read_packet(&mut cursor).unwrap();
        assert_eq!(packet, vec![0x01, 0xAA, 0xBB]);
    }

    #[test]
    fn read_packet_empty_payload() {
        let mut data = Vec::new();
        data.extend_from_slice(&0u32.to_be_bytes());

        let mut cursor = Cursor::new(data);
        let packet = read_packet(&mut cursor).unwrap();
        assert!(packet.is_empty());
    }

    #[test]
    fn read_packet_truncated_length_errors() {
        let mut cursor = Cursor::new(vec![0x00, 0x01]); // only 2 bytes, need 4
        assert!(read_packet(&mut cursor).is_err());
    }

    #[test]
    fn read_packet_truncated_payload_errors() {
        let mut data = Vec::new();
        data.extend_from_slice(&10u32.to_be_bytes()); // claims 10 bytes
        data.extend_from_slice(&[0x01, 0x02]); // only 2 bytes

        let mut cursor = Cursor::new(data);
        assert!(read_packet(&mut cursor).is_err());
    }

    #[test]
    fn send_then_read_roundtrip() {
        let buf: Arc<Mutex<Vec<u8>>> = Arc::new(Mutex::new(Vec::new()));
        send_packet(&buf, TAG_STDERR, b"error msg");

        let data = buf.lock().unwrap().clone();
        let mut cursor = Cursor::new(data);
        let packet = read_packet(&mut cursor).unwrap();

        assert_eq!(packet[0], TAG_STDERR);
        assert_eq!(&packet[1..], b"error msg");
    }
}
