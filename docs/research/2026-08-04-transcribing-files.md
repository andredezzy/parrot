# Transcribing files: what parrot needed, and what it still cannot match

Investigation prompted by wanting an agent to read WhatsApp voice notes with the
model parrot already loads, instead of installing a second engine beside it.

Everything below is measured on this machine against one 2m21s Portuguese voice
note (141s, 31 sentences), scored on ten terms whose mistranscription changes the
meaning of the message. The reference is faster-whisper `medium` int8 on CPU,
which is what the calling agent used before this work.

## Baseline to beat

| | Score | Chars | Time |
|---|---|---|---|
| faster-whisper `medium`, beam 5, CPU | **9/10** | 2263 | 130.8s |

Stable across runs. The one term it misses, "muito ansioso", no engine tested here
recovered.

## What was wrong in parrot, and is now fixed

`WhisperKitTranscriber` passed no `chunkingStrategy`. WhisperKit reads 30 seconds
at a time and, given no strategy, takes the branch its own source comments as
"audio is short enough to transcribe in a single window". A 141-second note went
through the short-audio path and lost nine of its thirty-one sentences, from the
middle, while still ending on the right words.

| `whisper-medium` | Score | Chars |
|---|---|---|
| before | 5/10 | 1276 |
| after `.vad` | 5/10 | 2159 |

Content recovered, and the run got *faster* (63s to 40s) because chunks decode
across concurrent workers. Dictation under thirty seconds never reaches the
strategy check, measured unchanged on a 12s clip.

## What was not the problem

Two plausible causes, both tested and both rejected:

- **The dictation-examples prompt.** Feeding a user's own dictation example to a
  third party's voice note sounded like it would steer the decode. Scored 5/10
  with and without.
- **Decoding thresholds.** WhisperKit's defaults already match faster-whisper's:
  `temperatureFallbackCount` 5, `compressionRatioThreshold` 2.4,
  `logProbThreshold` -1.0, `noSpeechThreshold` 0.6.

## Model size moves it more than anything else

The registry shipped only turbo variants, whose decoder is pruned from 32 layers
to 4. That pruning, not the runtime, is most of why Whisper looked weak here.

| Model | Score | Chars (cold / warm) |
|---|---|---|
| `large-v3-turbo` | 5/10 | 1321 / 2190 |
| `medium` | 5/10 | 1765 / 1276 |
| `large-v3` | 8/10 cold, **7/10 warm** | 2275 / 1811 |
| Parakeet TDT v3 | 6/10 | 2107 |

Read the warm column. The cold one includes ANE compilation and is not a
transcription measurement.

`whisper-medium` and `whisper-large-v3` are now registered.

## The retracted blocker: cold runs are not warm runs

An earlier version of this note claimed the same command returned different
amounts of text on repeat runs, and called it disqualifying. That was wrong, and
the error is worth keeping written down.

The pairs being compared were a first run against a second. Every first run
included downloading the model, and CoreML compiles a model for the ANE on first
use, so run one and run two were not the same machine state.

Run warm four times on the same real 2m16s note, `whisper-medium`:

| Run | Chars | md5 |
|---|---|---|
| 1 | 1901 | 609bc69a |
| 2 | 1901 | 609bc69a |
| 3 | 1901 | 609bc69a |
| 4 | 1901 | 609bc69a |

Identical. Three synthetic reproductions were also identical: clean 120s speech,
the same degraded to 16kbps Opus with noise at 1.18x speed, and one alternating
ten seconds clean with ten seconds degraded to force uneven decode times across
chunks. Twelve runs, no variation.

**Benchmark cold and warm separately, and never compare across them.** The first
run of a model measures download plus ANE compilation; only the second onward
measures transcription. The numbers in the model table above carry that flaw
where two figures appear, and the second of each pair is the trustworthy one.

## Why beam search is not the answer people expect

faster-whisper's quality comes from beam search with five candidates.
`BeamSearchTokenSampler` exists in argmax-oss-swift and is a stub: both `update`
and `finalize` are `fatalError("Not implemented")`. WhisperKit hardcodes
`GreedyTokenSampler` at both selection sites. Enabling beam search means writing
it, including reordering the KV-cache per candidate through a 915-line decoder
that assumes one live sequence.

Worth knowing before filing an issue asking for it to be "exposed".

## If a different decoder is ever wanted

Two ways to get beam search without writing it, compared on integration surface
rather than on benchmarks:

| | CTranslate2 (what faster-whisper wraps) | whisper.cpp |
|---|---|---|
| API | C++ only | C, `extern "C"` |
| Audio in | mel spectrogram, caller computes it | raw float32 |
| Tokenizer | caller supplies | built in |
| Beam | `beam_size`, default 5 | `params.beam_search.beam_size` |
| Acceleration | CPU only | Metal |
| Weights | CT2 directory | one GGML file |

CTranslate2 would import faster-whisper's 130 seconds along with its accuracy,
since that time is CPU inference rather than Python overhead. whisper.cpp asks
for a prebuilt XCFramework and a CMake step, which is the cost of leaving the
single-SPM-package property behind.

Neither is worth starting for a one-to-two term gap on a stable engine. What
would justify one is wanting beam search itself, not repairing something broken.
