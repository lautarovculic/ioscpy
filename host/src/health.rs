//! Connection health: the readable capability report plus the live session loop
//! that keeps the control channel alive and surfaces what the daemon sends.

use std::net::{Shutdown, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{Context, Result};

use crate::codec::CodecChoice;
use crate::h264::{Decoded, H264Decoder};
use crate::input::InputFrame;
use crate::protocol::{self, Capabilities, HelloAck, LogMessage, MessageType, CHANNEL_CONTROL};
use crate::video;
use crate::window::FrameSlot;

/// Print the capability map in a readable block. Shown after handshake and under
/// `--debug`.
pub fn print_capabilities(ack: &HelloAck) {
    let c: &Capabilities = &ack.capabilities;
    println!(
        "connected, daemon {} (protocol {})",
        ack.daemon_version, ack.protocol_version
    );
    println!("  device      {}  (iOS {})", c.device_model, c.ios_version);
    println!(
        "  jailbreak   {} (prefix {})",
        c.jailbreak_layout,
        prefix_or_root(&c.jb_prefix)
    );
    println!("  injection   {}", blank_as_unknown(&c.injection_framework));
    println!("  daemon uid  {}", c.daemon_uid);
    println!("  stream      {}", list_or_none(&c.stream_backends));
    println!("  input       {}", list_or_none(&c.input_backends));
    println!(
        "  clipboard   {}    keyboard {}    orientation {}",
        on_off(c.clipboard),
        on_off(c.keyboard),
        on_off(c.orientation),
    );
}

/// How a session ended.
pub enum SessionEnd {
    /// The user asked to quit (Ctrl-C).
    Quit,
    /// The link dropped; the caller should try to reconnect.
    Lost,
}

enum Incoming {
    Frame(protocol::Frame),
    Disconnected,
}

/// Hold the control channel open: ping on an interval, print the daemon's logs and
/// errors, and report when the link drops so the caller can reconnect.
///
/// A separate thread does the blocking reads while this thread drives the keepalive
/// and watches the pong deadline, so a silently dead peer still gets noticed.
pub fn run_session(
    stream: TcpStream,
    stop: Arc<AtomicBool>,
    frame_sink: Option<FrameSlot>,
    input_rx: Option<&Receiver<InputFrame>>,
    clip_in: Option<&Sender<String>>,
    codec_choice: CodecChoice,
    suppress_keyboard: bool,
) -> Result<SessionEnd> {
    stream.set_read_timeout(None).ok();
    let mut writer = stream.try_clone().context("clone control stream")?;
    let mut reader = stream.try_clone().context("clone control stream")?;

    // Ask the daemon to start streaming once we have somewhere to show it. The
    // payload starts with the codec and may carry conservative capture knobs for
    // device/OS combinations that are unstable under the legacy 1600px/45fps path.
    if frame_sink.is_some() {
        let _ = protocol::write_frame(
            &mut writer,
            MessageType::StartStream,
            CHANNEL_CONTROL,
            0,
            &crate::codec::start_stream_payload(codec_choice),
        );
    }

    // Hide the device's software keyboard for this session if asked. The device
    // also restores it on disconnect, so it can't get stuck hidden.
    if suppress_keyboard {
        let _ = protocol::write_frame(
            &mut writer,
            MessageType::KeyboardMode,
            CHANNEL_CONTROL,
            0,
            &protocol::encode_keyboard_mode(true),
        );
    }

    // Counts video frames so the main loop can tell if the stream stalls.
    let video_count = Arc::new(AtomicU64::new(0));
    let streaming = frame_sink.is_some();

    // Set by the reader when an H.264 frame won't decode, so the main loop knows to
    // ask the device for a fresh keyframe.
    let want_keyframe = Arc::new(AtomicBool::new(false));

    let (tx, rx) = mpsc::channel::<Incoming>();
    let sink = frame_sink.clone();
    let reader_count = video_count.clone();
    let reader_keyframe = want_keyframe.clone();
    let reader_stop = stop.clone();
    let reader_handle = thread::spawn(move || {
        // H.264 is stateful, so we decode here, in order, as frames arrive (can't
        // keep latest and decode later). The decoder is built on the first H.264
        // frame, which carries SPS/PPS. JPEG stays stateless.
        let mut h264: Option<H264Decoder> = None;
        loop {
            match protocol::read_frame(&mut reader) {
                Ok(frame) => {
                    if frame.message_type() == Some(MessageType::VideoFrame) {
                        if let Some(slot) = &sink {
                            if let Some((_, _, flags, data)) =
                                protocol::parse_video_payload(&frame.payload)
                            {
                                let decoded = if flags & protocol::VIDEO_FLAG_H264 != 0 {
                                    if h264.is_none() {
                                        h264 = H264Decoder::new();
                                    }
                                    match h264.as_mut().map(|d| d.decode(data)) {
                                        Some(Decoded::Frame(f)) => Some(f),
                                        Some(Decoded::Failed) | None => {
                                            // Lost sync (or no decoder), ask for a
                                            // fresh keyframe to recover.
                                            reader_keyframe.store(true, Ordering::Relaxed);
                                            None
                                        }
                                        Some(Decoded::Pending) => None,
                                    }
                                } else {
                                    // JPEG: latest-only, decoded here so the window
                                    // just blits.
                                    video::decode_jpeg(data)
                                };
                                if let Some(f) = decoded {
                                    // Capture is always portrait, so rotate it
                                    // upright per the device's reported orientation.
                                    let turns =
                                        video::upright_turns(protocol::video_orientation(flags));
                                    let f = video::rotate_cw(f, turns);
                                    *slot.lock().unwrap() = Some(f);
                                }
                            }
                        }
                        reader_count.fetch_add(1, Ordering::Relaxed);
                    } else if tx.send(Incoming::Frame(frame)).is_err() {
                        break;
                    }
                }
                Err(e) => {
                    if !reader_stop.load(Ordering::Relaxed) {
                        crate::warn!("reader stopped: {e}");
                        let _ = tx.send(Incoming::Disconnected);
                    }
                    break;
                }
            }
        }
    });

    let ping_every = Duration::from_secs(3);
    let pong_deadline = Duration::from_secs(10);
    let mut seq = 1u64;
    let mut last_ping = Instant::now()
        .checked_sub(ping_every)
        .unwrap_or_else(Instant::now); // so we ping right away
    let mut last_pong = Instant::now();
    let video_stall = Duration::from_secs(4);
    let mut last_video_count = 0u64;
    let mut last_video_progress = Instant::now();
    let mut last_keyframe_req = Instant::now()
        .checked_sub(Duration::from_secs(1))
        .unwrap_or_else(Instant::now);

    let outcome = loop {
        if stop.load(Ordering::Relaxed) {
            break SessionEnd::Quit;
        }

        // While streaming, frames should keep arriving. A long gap means the stream
        // wedged, so reconnect to respawn it rather than freeze forever.
        if streaming {
            let count = video_count.load(Ordering::Relaxed);
            if count != last_video_count {
                last_video_count = count;
                last_video_progress = Instant::now();
            } else if last_video_progress.elapsed() > video_stall {
                crate::warn!("video stalled, reconnecting");
                break SessionEnd::Lost;
            }
        }

        // Video frames are already a high-frequency liveness signal. While they
        // are flowing, avoid extra ping/pong writes on the control stream; older
        // usbmux/device combinations have proven sensitive to needless duplex
        // control traffic during capture startup.
        let video_recent = streaming && last_video_progress.elapsed() <= ping_every;
        if video_recent {
            last_pong = Instant::now();
        }
        if !video_recent && last_ping.elapsed() >= ping_every {
            if protocol::write_frame(&mut writer, MessageType::Ping, CHANNEL_CONTROL, seq, &[])
                .is_err()
            {
                break SessionEnd::Lost;
            }
            seq += 1;
            last_ping = Instant::now();
        }

        // If the H.264 decoder lost sync, ask for a fresh keyframe. Rate-limited so
        // a bad patch can't flood the control channel.
        if want_keyframe.swap(false, Ordering::Relaxed)
            && last_keyframe_req.elapsed() >= Duration::from_millis(500)
        {
            last_keyframe_req = Instant::now();
            if protocol::write_frame(
                &mut writer,
                MessageType::RequestKeyframe,
                CHANNEL_CONTROL,
                seq,
                &[],
            )
            .is_err()
            {
                break SessionEnd::Lost;
            }
            seq += 1;
        }

        // Forward queued input to the device promptly.
        if let Some(rx_in) = input_rx {
            let mut failed = false;
            while let Ok(frame) = rx_in.try_recv() {
                if protocol::write_frame(
                    &mut writer,
                    frame.msg_type,
                    CHANNEL_CONTROL,
                    seq,
                    &frame.payload,
                )
                .is_err()
                {
                    failed = true;
                    break;
                }
                seq += 1;
            }
            if failed {
                break SessionEnd::Lost;
            }
        }

        match rx.recv_timeout(Duration::from_millis(16)) {
            Ok(Incoming::Frame(frame)) => match frame.message_type() {
                Some(MessageType::Pong) => last_pong = Instant::now(),
                Some(MessageType::Log) => print_log(&frame.payload),
                Some(MessageType::Error) => print_error(&frame.payload),
                Some(MessageType::ClipboardChanged) => {
                    // [flags:u8][utf8]; hand the text to the window thread, which
                    // owns the pasteboard and sync bookkeeping (and the main thread).
                    if let (Some(tx), true) = (clip_in, frame.payload.len() >= 1) {
                        let text = String::from_utf8_lossy(&frame.payload[1..]).into_owned();
                        let _ = tx.send(text);
                    }
                }
                _ => {}
            },
            Ok(Incoming::Disconnected) => break SessionEnd::Lost,
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => break SessionEnd::Lost,
        }

        if last_pong.elapsed() > pong_deadline {
            crate::warn!("no response from ioscpyd for {}s", pong_deadline.as_secs());
            break SessionEnd::Lost;
        }
    };

    // Stop capture before tearing down the USB control socket. On older devices,
    // closing the socket while SpringBoard is still pushing frames can destabilize
    // usbmux/lockdown; bench/snapshot already stop explicitly, so do the same for
    // the live session loop.
    if streaming {
        let _ = protocol::write_frame(
            &mut writer,
            MessageType::StopStream,
            CHANNEL_CONTROL,
            0,
            &[],
        );
    }

    // Restore the device keyboard if we hid it. Best-effort: the device also
    // restores on disconnect, so a failed write here is harmless.
    if suppress_keyboard {
        let _ = protocol::write_frame(
            &mut writer,
            MessageType::KeyboardMode,
            CHANNEL_CONTROL,
            0,
            &protocol::encode_keyboard_mode(false),
        );
    }

    // Unblock the reader thread and join it before returning.
    let _ = writer.shutdown(Shutdown::Both);
    let _ = reader_handle.join();
    Ok(outcome)
}

fn print_log(payload: &[u8]) {
    if let Ok(log) = serde_json::from_slice::<LogMessage>(payload) {
        println!("device[{}] {}", log.level, log.message);
    }
}

fn print_error(payload: &[u8]) {
    if let Ok(e) = serde_json::from_slice::<protocol::DaemonError>(payload) {
        let tag = if e.fatal { "error" } else { "warning" };
        eprintln!("ioscpy: device {tag} [{}] {}", e.code, e.message);
        if !e.suggestion.is_empty() {
            eprintln!("        {}", e.suggestion);
        }
    }
}

fn prefix_or_root(p: &str) -> &str {
    if p.is_empty() {
        "/"
    } else {
        p
    }
}

fn blank_as_unknown(s: &str) -> &str {
    if s.is_empty() {
        "unknown"
    } else {
        s
    }
}

fn list_or_none(v: &[String]) -> String {
    if v.is_empty() {
        "none".to_string()
    } else {
        v.join(", ")
    }
}

fn on_off(b: bool) -> &'static str {
    if b {
        "on"
    } else {
        "off"
    }
}
