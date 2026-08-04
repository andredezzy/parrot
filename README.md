# parrot

A minimal macOS dictation daemon. Push-to-talk, on-device transcription, text inserted at the cursor.

> A fork of [digimata/parrot](https://github.com/digimata/parrot) for people who
> do not dictate only in English. Adds input gain correction, a microphone
> picker, a model switcher with Parakeet as the default, and per-language
> dictation examples — each measured on 32 real recordings rather than argued.
> [What changed, with numbers](https://github.com/andredezzy/parrot/releases/latest).

## Install

```sh
curl -fsSL https://andredezzy.github.io/parrot/install.sh | sh
parrot setup                       # grants mic + accessibility, downloads the model
parrot install --launch-at-login   # optional — runs in the background on login
```

**Requires:** macOS 14+ on Apple Silicon (M1 or newer). Transcription runs on the Apple Neural Engine via CoreML — so the installer refuses to run on Intel.

The installer drops the binary in `/usr/local/bin/parrot`. Builds are unsigned, so the installer strips the quarantine xattr — once you've inspected the script you'll see exactly what it does.

macOS re-asks for Accessibility whenever a binary's signature changes, so each release means granting it again. `scripts/install-local.sh` builds from source and signs with a stable per-machine identity, which keeps the grant across updates.

## How to use

1. **Run it.** Either `parrot install --launch-at-login` (daemonized, runs forever, lives in the menu bar), or `parrot` in any terminal tab.
2. **Click into the text field you want to dictate into** — Messages, the address bar, a Slack thread, anywhere a cursor blinks.
3. **Hold the `fn` key, speak, release.** A small pill appears at the bottom of the screen while the mic is hot.
4. **The transcript types itself in at the cursor** when you release. Usually within 200-300ms.

That's it. There is no record button, no stop button, no "send" — `fn` is the whole interface.

> **Note:** on most modern Macs the `fn` key is the bottom-left key. If yours is set to "Change input source" or "Show emoji & symbols," `parrot setup` will tell you how to flip it back to plain `fn`.

## CLI

```sh
parrot                                 # run in the foreground (^C to quit)
parrot setup                           # one-time setup: permissions + model download
parrot install --launch-at-login       # register a LaunchAgent (background daemon)
parrot install --uninstall             # remove the LaunchAgent
parrot doctor                          # check permissions + fn key setting
parrot models list                     # list available models
parrot models download <id>            # pre-download a model
parrot transcribe a.ogg b.m4a          # transcribe files that already exist
parrot transcribe note.ogg --language pt   # pin the decode instead of detecting it
parrot --model whisper-large-v3-turbo-compressed  # better on technical terms, ~10x slower
parrot --hotkey right-option           # change the push-to-talk key
parrot --no-overlay                    # disable the bottom-of-screen pill
```

`transcribe` exists because the model loaded for the `fn` key is the same one an
agent needs to read a voice note somebody sent, and a second tool would download a
second copy of weights already on disk. Pass every file in one call: loading costs
seconds and decoding costs milliseconds, so twenty files in one invocation is one
warm-up instead of twenty. Ogg/Opus decodes natively, so a WhatsApp note needs no
ffmpeg detour.

**Pass `--language` whenever you know it.** Unpinned, Whisper translates a
Portuguese recording into English sentences rather than transcribing it. Dictation
gets away without it because the dictation-examples file usually names one
language; a file handed to the CLI carries no such hint.

The menu bar carries the rest, because they are decisions you change while
using it rather than when launching it:

- **Input** — which microphone to record from. Recording raises a turned-down
  one to a measured optimum and puts your value back on stop.
- **Model** — switch engines without restarting. The model in use and the one
  you switched away from stay on disk; everything else is deleted.
- **Edit dictation examples…** — one sentence per language, in your own words,
  handed to Whisper before it decodes. Ignored by Parakeet, which cannot read
  text. Worth 39 points of technical-term recall; the file explains the format.

## Stack

- **Swift** — single SPM executable target
- **WhisperKit** — Whisper inference via CoreML, ANE-accelerated
- **AVAudioEngine** — mic capture
- **CGEventTap** — global hotkey
- **CGEvent** — text injection at cursor
- **NSWindow** (borderless, click-through) — recording-indicator pill

See [docs/architecture.md](docs/architecture.md) for design notes.

## Build from source

```sh
swift build -c release
.build/release/parrot --help
```
