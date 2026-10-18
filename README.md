# LCP — Lecture Capture Pipeline

An end-to-end personal lecture ingestion and synthesis system. LCP pairs a zero-window macOS menu bar client with an automated, self-hosted transcription engine running on an Ubuntu server rack with an Nvidia GTX 1070 Ti, feeding transcripts into Hermes Agent for context-grounded Q&A via OpenAI.

---

## Architecture

[ MacBook M1 in Class ]
   |
   |  1. Record via LCP Menu Bar App (16 kHz Mono AAC / .m4a)
   v
[ ~/Lectures/Incoming/ ]
   |
   |  2. Syncthing (over Tailscale / local network)
   v
[ Ubuntu Server: /data/lectures/inbox/ ]
   |
   |  3. Ingestion daemon (daemon.py) detects file close
   |  4. faster-whisper on GTX 1070 Ti (compute_type: int8_float16)
   v
[ /data/lectures/vault/<COURSE>/<COURSE>_<TIMESTAMP>.md ]
   |
   |  5. Hermes Agent custom skill reads local markdown notes
   v
[ Hermes Agent (Q&A via OpenAI API) ]

---

## Components

### 1. macOS Client (LCP.app)
- **UI:** Menu-bar-only resident utility (`LSUIElement = YES`).
- **Audio Output:** 16,000 Hz, 1 channel (mono), 32 kbps AAC (`.m4a`). ~20–30 MB for a 90-minute lecture.
- **Naming Pattern:** `<COURSE>_<YYYY-MM-DD_HHmm>.m4a` saved to `~/Lectures/Incoming/`.

### 2. Transport & Sync (Syncthing + Tailscale)
- **Mac Directory:** `~/Lectures/Incoming` (Folder Type: *Send Only*)
- **Server Directory:** `/data/lectures/inbox` (Folder Type: *Receive Only*)
- **Folder ID:** `lecture-inbox`
- **Headless Access:** Web GUI accessed via SSH tunnel (`ssh -L 9384:127.0.0.1:8384 user@server-ip` -> `http://localhost:9384`).

### 3. Server Ingestion Daemon (daemon.py)
- Watches `/data/lectures/inbox` for completed writes (`IN_CLOSE_WRITE`).
- Model: Faster-Whisper `medium.en` with VAD filtering enabled.
- Hardware: GTX 1070 Ti running `int8_float16` (Compute Capability 6.1 optimized).
- Output: Structured Markdown files with `[MM:SS]` timestamps written to `/data/lectures/vault/<COURSE>/`.
- Archival: Moves source audio to `/data/lectures/archive/`.

### 4. Knowledge Agent (Hermes Agent)
- Local Hermes Agent instance pointing to OpenAI API (`gpt-4o` / `gpt-4o-mini`).
- Custom skill configured at `~/.hermes/skills/lecture_vault/SKILL.md` to search and cite lecture notes.

---

## Directory Setup (Server)

```bash
sudo mkdir -p /data/lectures/{inbox,archive,vault}
sudo chown -R $USER:$USER /data/lectures
```

---

## Server Watcher Quickstart

```bash
cd ~/lecture-pipeline
python3 -m venv venv
source venv/bin/activate
pip install faster-whisper watchdog
python3 daemon.py
```

---

## License

MIT
