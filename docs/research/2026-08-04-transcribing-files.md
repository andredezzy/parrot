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

| Model | Score | Chars |
|---|---|---|
| `large-v3-turbo` | 5/10 | 1321 / 2190 |
| `medium` | 5/10 | 1276 / 1765 |
| `large-v3` | **8/10 / 7/10** | 2275 / 1811 |
| Parakeet TDT v3 | 6/10 | 2107 |

`whisper-medium` and `whisper-large-v3` are now registered.

## The blocker: the same command does not give the same answer

Two columns of characters above, because every Whisper model tested returns a
different amount of text on a second run of an identical command. `large-v3`
gave 2275 characters then 1811. `medium` gave 1765 then 1276. VAD chunking
reduced the loss without removing it.

Nothing signals which run was short. A caller cannot tell a complete transcript
from one missing a third of the audio, which is disqualifying for reading a
conversation someone will act on — more than any accuracy score is.

faster-whisper did not vary across the runs made here.

**This is unexplained.** Candidates not yet eliminated: VAD chunk boundaries
moving between runs, the temperature-fallback path taking different branches, or
concurrent workers racing. It wants isolating before any WhisperKit-based path is
trusted for long audio, and it may be worth reporting upstream.

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

Neither is worth starting before the nondeterminism above is understood, since a
second decoder would not explain the first one's behaviour.
