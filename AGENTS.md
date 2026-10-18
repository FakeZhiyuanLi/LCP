# AGENTS.md — LCP Context & Codex Instructions

This document defines the system boundaries, interfaces, coding standards, and operational assumptions for AI agents (Codex, Claude Code, Cursor) developing the LCP repository.

---

## 1. Project Overview & Scope

LCP consists of two decoupled subsystems in this repository:
1. **macOS Client (`/client`):** A lightweight SwiftUI menu bar app that records audio in class and writes to a staged directory.
2. **Server Worker (`/server`):** A Python ingestion watcher that monitors incoming audio, transcribes it via `faster-whisper` on an Nvidia GTX 1070 Ti, outputs structured Markdown, and registers notes with Hermes Agent.

---

## 2. macOS Client Specifications (`/client`)

### Tech Stack
- Swift 5.9+, SwiftUI, `AVFoundation`.
- macOS target: 14.0+ (Sonoma / Sequoia).
- App model: Menu Bar Extra (`MenuBarExtra`), no Dock icon (`LSUIElement = true`).

### Audio Recording Configuration
- **Container / Codec:** `.m4a` / MPEG-4 AAC (`kAudioFormatMPEG4AAC`).
- **Sample Rate:** `16000.0` Hz.
- **Channels:** `1` (Mono).
- **Bitrate:** `32000` bps.
- **Audio Quality:** `AVAudioQuality.medium`.

### Path & Naming Convention
- **Staging Directory:** `~/Lectures/Incoming/` (must be created automatically if missing).
- **Naming Pattern:** `<COURSE>_<YYYY-MM-DD_HHmm>.m4a` (e.g., `CS182_2026-10-18_1430.m4a`).

### Required Permissions & Entitlements
- `Info.plist`: `Privacy - Microphone Usage Description` (`NSMicrophoneUsageDescription`).
- App Sandbox: If enabled, require `com.apple.security.device.audio-input`. For development builds, disabling App Sandbox is preferred to allow direct file writes to `~/Lectures/Incoming`.

### Critical Client Edge Cases
- Clean termination: Ensure `AVAudioRecorder.stop()` is invoked if the app receives termination signals (`applicationWillTerminate`) so files are not corrupted.
- Visual state: Toggle menu bar icon between `mic.fill` (idle) and `record.circle.fill` with live `MM:SS` duration counter (recording).

---

## 3. Server Ingestion Specifications (`/server`)

### Operational Environment
- **OS:** Ubuntu Desktop 22.04 / 24.04 LTS.
- **GPU:** Nvidia GeForce GTX 1070 Ti (8 GB VRAM, Pascal CC 6.1).
- **Sync Transport:** Syncthing (Folder ID: `lecture-inbox`).

### Directory Layout
```text
/data/lectures/
├── inbox/           # Syncthing destination (Receive Only)
├── archive/         # Processed raw audio files
└── vault/           # Transcribed markdown notes (consumed by Hermes Agent)
    └── <COURSE>/
        └── <COURSE>_<TIMESTAMP>.md
```

### Transcription Engine
- Package: `faster-whisper`.
- Model: `medium.en` (or `large-v3`).
- Compute Type: `int8_float16` (avoids FP16 performance degradation on Pascal GPUs).
- VAD Filter: Enabled (`min_silence_duration_ms=500`) to strip dead lecture space.

### Output Markdown Schema
Every generated note must follow this structure:
```markdown
# Lecture Notes: <FILENAME_STEM>

- **Course:** <COURSE>
- **Duration:** <MINUTES> minutes

## Transcript

**[00:00]** First transcribed segment...

**[00:15]** Second transcribed segment...
```

---

## 4. Hermes Agent Skill Definition

Location on server: `~/.hermes/skills/lecture_vault/SKILL.md`

```markdown
# Lecture Vault Search Skill

## Description
Search, read, and synthesize lecture notes and transcripts from `/data/lectures/vault/`.

## Capabilities
- Search course subdirectories: `/data/lectures/vault/<COURSE>/`
- Scan transcripts for concepts, formulas, and discussions.
- Ground answers strictly in transcripts, citing exact lecture dates and timestamps `[MM:SS]`.
```

---

## 5. Development Rules for Agents

1. **Keep Subsystems Decoupled:** Never add server networking, SSH, or transcription logic inside the macOS Swift client. The client's only output is writing `.m4a` files into `~/Lectures/Incoming/`.
2. **Deterministic File Watcher:** The Python server watcher must trigger on `on_closed` / `IN_CLOSE_WRITE` to ensure Syncthing has fully synced the file before transcription starts.
3. **No Uncompressed WAVs:** Always enforce 16 kHz Mono AAC (`.m4a`) or Opus to keep sync payload sizes under 35 MB per lecture.
