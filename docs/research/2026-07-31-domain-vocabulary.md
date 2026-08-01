# Domain vocabulary and code-switched dictation: what actually works

Investigation into how a general-purpose dictation app can get domain-specific
words and mixed-language speech right, for users of any profession — without
asking anyone to maintain a word list.

Every claim below is either measured on this machine or cited to a primary
source. Measurements use an 8-utterance corpus of real dictation (mixed
Portuguese/English, 66 words) recorded through parrot itself.

## Baseline

`whisper-large-v3-turbo`, no decoding options, as parrot ships:

| | value |
|---|---|
| Word accuracy | **89.4%** (7 errors / 66 words) |
| Utterances perfect | 4/8 |
| Latency | 0.6–2.5 s |

Error distribution matters more than the average: **every error is an English
technical noun inside Portuguese speech** (`pull requests` → `por request`,
`backend` → `back-end`) **or a one-word utterance** (`Sim` → `Sing`). Natural
prose in either language transcribed with zero errors across 32 words.

This reframes the problem: it is not general accuracy, it is code-switched
proper nouns. A monolingual user of any profession does not hit it.

## Mechanisms tested, measured on this machine

### Whisper prompt conditioning (`promptTokens`) — BROKEN in WhisperKit 0.18

| flags | result |
|---|---|
| `usePrefillPrompt: true` (default) + prompt | **7 of 8 utterances EMPTY** |
| `usePrefillPrompt: false` + prompt | 8/8 text, but prompt **inert** — target errors unchanged |

The one utterance that survived with prefill on produced exactly the desired
`backend` instead of `back-end`, so the biasing works when it runs — the
implementation is what fails. WhisperKit's own source carries a matching TODO:
prefill cache "currently breaks if it starts at non-zero index"
(`Sources/WhisperKit/Core/TextDecoder.swift`).

Verdict: no usable positive-biasing path in WhisperKit today. Worth an upstream
issue regardless of what parrot decides.

### On-device LLM post-processing (Apple `FoundationModels`, ~3B) — UNUSABLE

Available and `available` on this machine; latency acceptable (0.4–1.6 s). But
on the 8 real transcriptions, with explicit instructions not to translate:

- `O deploy do back-end quebrou de novo` → `I deployed the backend again`
  (translated **and** inverted the meaning)
- `Now test me speaking a long phrase…` → `"I'm sorry, but I'm not sure I
  understand what you're saying. Can you please repeat yourself?"` (hallucinated)
- Two of eight emitted a chat preamble despite instructions

Verdict: a mechanism that can rewrite a correct sentence is unacceptable here.
Losing the user's words is far worse than one misheard noun.

### Apple `SpeechTranscriber` (macOS 26) as the engine — WORSE ACCURACY, MUCH FASTER

Same corpus, ground-truth locale per utterance (its best case, since it supports
one locale per session):

| | Whisper turbo | Apple SpeechTranscriber |
|---|---|---|
| Word accuracy | **89.4%** | 81.8% |
| Latency | 0.6–2.5 s | **0.08–0.38 s** |
| Model download | 1.6 GB | none, OS-owned |
| `backend` (05) | ✗ `back-end` | ✓ correct |
| Long English (08) | ✓ clean | ✗ `Now, testing is speaking, uh, longer phrasing` |

The published 2.12% WER for this engine is clean read English; it does not
transfer to real dictation with code-switching. The difference is systematic:
Apple transcribes literally, including fillers; Whisper produces clean written
text, which is what dictation wants.

### Apple `contextualStrings` biasing — WORKS, on a weaker model

`DictationTranscriber` is the only engine here with functioning positive
biasing. With hints `["pull request", "pull requests", "backend", "merge",
"deploy"]`:

```
02  no hints  : Let me check the request
    with hints: Let me check the pull request        ← fixed exactly
05  no hints  : O depósito do Backend quebrou de novo
    with hints: O depósito do backend quebrou de novo  ← only the casing
04  with hints: Preciso revisar os recorrentes do mar  ← unrecoverable
```

The pattern: biasing rescues a **near** hypothesis (`request` → `pull request`),
never a **wrong** one (`depósito` for `deploy`). And this engine's pt-BR model is
weaker than Whisper's, so it loses overall even with biasing working.

### Language configuration — no lever

Text was byte-identical under `<|en|>`, `<|pt|>` and auto-detection on turbo.
Unconditional detection regressed real usage (English audio transcribed as a
Portuguese translation) and was reverted. Detection confidence on the corpus
ranged 36%–100% with all 8 detections correct, so a confidence gate would have
rejected two correct detections and saved one wrong one — a wash.

### Input gain — no lever

Corpus peaks measured ~0.099 (≈19 dB of unused headroom). Normalising to 0.95
changed nothing on 7 of 8 utterances and **degraded** the eighth. Whisper's
log-mel front-end already normalises; the headroom is irrelevant to the model.

### Bigger model (`large-v3`, full) — trades errors, and is dangerous with a pinned language

Fixed `check` where turbo said `share`, and produced `Yes. Sim.` — the only
correct code-switched output seen in the entire investigation. But it broke a
long English sentence, added spurious punctuation, and **obeys the language
token**: with parrot's current `<|en|>` pin it translated every Portuguese
utterance into English. Load 1305 s on CPU+GPU, 3–7 s per utterance.

Note the coupling this exposes: turbo is accidentally robust *because* it ignores
the language token. A non-distilled model makes correct language handling a
prerequisite, not an optimisation.

## What the ecosystem offers (research, primary sources)

- **whisper.cpp hotwords**: not implemented; open feature request #1979.
- **faster-whisper hotwords**: prompt-based, therefore carries the same
  empty-output and language-bias risks as `initial_prompt`.
- **WhisperKit `LogitsFiltering`**: suppression only. No positive boosting hook.
- **Shallow fusion with an external LM**: 300–1500 ms added latency — breaks a
  hold-to-talk dictation budget.
- **Prefix-trie constrained beam search**: 5–20 ms, the only mechanism that is
  both safe and effective, but 4–7 weeks of work and WhisperKit has no beam
  search at all (greedy sampler only; `topK` applies solely when
  `temperature > 0`).
- **TCPGen and similar pointer-generator biasing**: requires training.
- **Code-switching in Whisper**: one language token per 30 s window is
  architectural. Modern unified multilingual models (Deepgram Flux Multilingual,
  AssemblyAI Universal-3 Pro) handle intra-sentence mixing natively; none is
  available on-device in CoreML today.

**Industry practice**, from vendor docs: biasing is prompt conditioning at
inference with a 100–500 token budget, and the vocabulary is **derived
automatically from application context** — contacts, calendar, the current
screen, database entity names — never from a list the end user maintains.
Consumer products adapt via federated learning (Gboard) or profile harvesting
from the user's own documents (Dragon). Over-biasing above ~100 terms is
documented to degrade accuracy.

**Automatic sources available to this app**, needing no new permission beyond the
Accessibility grant parrot already holds: the focused text field's existing
content, window title, frontmost app identity, spell-checker learned words, git
identifiers in the working directory. The standard name for assembling the bias
list per utterance from live context is *shallow-fusion contextual biasing*.

## Conclusion

No mechanism available today combines zero user maintenance, no risk to correct
output, and a measurable gain inside the latency budget:

| mechanism | works? | safe? | maintenance | verdict |
|---|---|---|---|---|
| WhisperKit prompt | **no** (empty or inert) | no | list | blocked by library bug |
| On-device LLM pass | yes | **no** (rewrites, translates) | none | rejected |
| Apple engine swap | yes | yes | none | **−7.6 pts accuracy** |
| Apple + contextualStrings | yes | yes | auto-derivable | still net worse |
| Language config | no effect | detection regresses | none | rejected |
| Gain normalisation | no effect | slightly harmful | none | rejected |
| Bigger Whisper model | trades errors | needs correct language | none | not a win |
| Prefix-trie decoding | would work | yes | none | 4–7 weeks, no beam search in WhisperKit |

**Recommendation: change nothing in the recognition path.** The current
configuration is the measured optimum, the residual errors are confined to
code-switched technical nouns, and monolingual dictation — the general case — is
already error-free on this corpus.

Two actionable items that are not features:

1. **The WhisperKit prompt bug.** Positive biasing is the mechanism the whole
   industry uses, and it is unavailable to every WhisperKit consumer: in the
   configuration where it biases it empties the output, and in the other it is
   inert. Fixing it upstream would unblock the automatic-context design for any
   app, not just parrot. Recorded here rather than filed.
2. **Behavioural, zero cost:** longer natural phrases transcribe perfectly
   (15–17 word utterances: 0 errors). Two-word utterances are the worst case,
   because the model has no context to disambiguate.

## Reproducing

Everything needed is committed next to this file, on branch
`scratch/ab-language`:

- `harnesses/corpus.tar.gz` — the 8 recordings plus the transcription parrot
  produced for each. `tar -xzf` into `/tmp`.
- `harnesses/whisperkit-prompt-flags.swift` — the prompt/prefill flag matrix.
  Build as the `abtest` target of this package.
- `harnesses/apple-speech-transcriber.swift` and `apple-contextual-bias.swift` —
  the Apple engines. Standalone:
  `swiftc -O -target arm64-apple-macos26 <file> -o run -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist`
  The embedded `Info.plist` is required: the Speech framework traps without
  `NSSpeechRecognitionUsageDescription`.
- `harnesses/foundation-models-cleanup.swift` — the on-device LLM pass.
- `harnesses/coreaudio-device-probe.swift` — device properties, including the
  private-aggregate discriminator.


Each experiment takes about 40 s against the corpus.

## Follow-up: rolling audio context (measured, rejected)

Whisper conditions later windows on earlier text *within one audio stream*, and
that path works where the external `promptTokens` API does not. Splicing the
previous utterance's audio in front of the current one therefore looked like a
way to buy context with no user maintenance and no risk of propagating a wrong
transcription — it conditions on what was actually said, not on what was
previously written.

Trimming is clean: with 11.20 s of context, segments came back at 0–3, 3–6,
6–11 and **11–14.5 s**, so filtering by segment start recovers exactly the new
utterance. Cost was +0.34 s.

It still made the corpus worse:

| | errors / 84 words | accuracy |
|---|---|---|
| each utterance alone | 7 | **91.7%** |
| preceded by the previous utterance | 18 | 78.6% |

Two utterances improved (`Yes. Sing.` → `Yes. Sim.`, and `revisá-los` →
`revisar os`). One regressed catastrophically: a Portuguese utterance preceded by
English context came out **translated into English** — 13 of the 18 errors.

The first, optimistic reading of this mechanism came from a rigged test: the
context audio used happened to contain the exact terms the target utterance was
getting wrong. Real rolling context is the *previous* utterance, which does not
contain the next one's vocabulary, so the gain evaporates and only the risk
remains.

## The structural finding

Five independent mechanisms were measured, and every one of them fails the same
way:

| mechanism | observed failure |
|---|---|
| text prompt | empties the output, or translates |
| rolling audio context | translates |
| language detection | translates |
| larger model (`large-v3`) | translates (it obeys the pinned token) |
| smaller models (`small`, `base`) | translate |

Anything that tells Whisper more about what to expect also gives it a way to be
wrong about the language. The shipped configuration works *because* turbo, with a
pinned language and no context, has nothing to be dragged by — its robustness is
the absence of context, not the presence of quality.

This is not a vocabulary problem. It is a language-identity problem, and none of
the available mechanisms separates "knowing which words to expect" from
"deciding which language to write in".

## Follow-up: a user-maintained word list (measured, declined)

Two shapes were considered once a maintained list was on the table.

**Fuzzy matching against the user's vocabulary.** The appeal: the user lists the
words they actually say ("pull requests", "backend") once, and phonetically close
mis-hearings snap to them, so the list is keyed to the user's vocabulary rather
than to the model's ever-changing mistakes. Measured against the real errors from
this session on one side, and ordinary Portuguese on the other:

| similarity threshold | errors fixed | false positives | what it corrupted |
|---|---|---|---|
| 0.70 | 3/5 | 2/10 | `comitê`→`commit`, `merece`→`merge` |
| 0.74 | 3/5 | 1/10 | `comitê`→`commit` |
| 0.78 | 1/5 | 1/10 | `comitê`→`commit` |
| 0.82 | 0/5 | 1/10 | `comitê`→`commit` |
| 0.86 | 0/5 | 0/10 | — |

There is no operating point. Where it fixes anything it also rewrites common
Portuguese words, because `comitê`/`commit` and `merece`/`merge` genuinely are
close. Phonetic similarity cannot tell "an English technical term the user spoke"
from "a Portuguese word that sounds like one", and corrupting correct text is the
one outcome ruled out from the start.

**Exact replacement.** Safe by construction — it touches only the literal strings
listed, so no calibration and no false positives. Three entries would have covered
every mis-hearing observed on the shipped configuration (`por request`,
`por requestes`, `back-end`). Declined anyway, and correctly: it repairs
consistent mis-hearings in the output, it does not bias recognition, so it carries
maintenance without addressing the actual problem. A mechanism that does not pay
for its own upkeep should not exist.

## Where this leaves the goal

Confident mixed-language dictation is not achievable today with any mechanism
reachable from WhisperKit. Eight were measured: text prompt, rolling audio
context, language detection, larger model, smaller models, input gain,
timestamp suppression, and a maintained word list in two shapes. The shipped
configuration is the measured optimum.

What does work, reproducibly and with no code: length. Utterances of 11 s and
longer transcribed every technical term correctly, including a spoken list of
`pull request, deploy, back-end, front-end, underrated, overrated`. Utterances
under ~4 s are where the errors live, because the sentence carries too little
structure to disambiguate them.

## Follow-up: a second engine (measured, shipped as a choice)

Parakeet TDT 0.6b v3 (CoreML, via FluidAudio) on the same eight recordings,
against `large-v3-turbo`, same ground truth, same word-level scoring:

| sample | turbo | parakeet | |
|---|---|---|---|
| 02 `Let me check the pull request` | 1 error (`share`) | 0 | parakeet |
| 04 `pull requests` at 0.7 input gain | 3 | 1 | parakeet |
| 05 `backend` | 1 (`back-end`) | 0 | parakeet |
| 06 `Yes` + `Sim` in one utterance | 1 (`Sin`) | 0 | parakeet |
| 07 long sentence, pt | 0 | 2 | turbo |
| 08 long sentence, en | 0 | 4 | turbo |
| 09 spoken list of terms | 0 | 4 | turbo |
| **total** | **10 / 92 — 89.1%** | **14 / 92 — 84.8%** | |

Turbo wins in aggregate. The distribution is the finding: Parakeet wins every
short utterance carrying an English technical term and loses every long
sentence, at 0.07-0.11 s per utterance against 0.6-2.5 s.

Three things it does with no configuration that seven measured mechanisms
failed to do: `backend` unhyphenated, `pull requests` intact, and `Yes, sim` —
both languages in one utterance, which the language-detection experiments above
concluded was unreachable.

Two traps worth naming. `UnifiedAsrManager` silently downloads
`parakeet-unified-en-0.6b`, an English-only build: measured against Portuguese
it produces `Bonjetut Puraki` for `Bom dia, tudo certo por aqui`, which reads
like a bad multilingual model rather than the wrong model. And its `language:`
parameter filters by *script*, so it cannot separate two Latin-script languages.

Shipped as a registry entry rather than a default or an automatic router: which
side of that trade matters depends on how a person dictates, and the corpus that
measured it is one speaker.

### Input gain, measured across three points

Same phrase, same microphone, differing only in the analog input gain CoreAudio
exposes as `kAudioDevicePropertyVolumeScalar`:

| gain | peak | clipped samples | 1.5-3.5 kHz energy | result |
|---|---|---|---|---|
| 0.133 (as found) | 0.083 | 0 | baseline | `revisá-los por request` |
| 0.700 | 0.375 | 0 | +11.6 dB | parakeet: `pull requests` correct |
| 0.900 | 1.000 | 566 | +14.0 dB | `o recurso`; one dictation transcribed empty |

The 0.9 point has more consonant-band energy and transcribes worse: the extra
energy is clipping distortion, not speech. This is the same reason digital
normalisation did nothing — level is not information. A MacBook's built-in
microphone defaulting to 13% gain is worth checking before blaming the model.

## Autonomous round: seven more mechanisms, one survivor

Measured on a fresh 8-utterance corpus recorded at corrected input gain, with
ground truth taken from the speaker's own corrections rather than from any
engine's output. Baseline (Parakeet TDT v3, stock config): **94.7% word
accuracy, 62% technical-term recall, 0.31 s per utterance**.

| mechanism | result |
|---|---|
| English token blocklist (`language: .portuguese`) | byte-identical output on every sample |
| `melChunkContext: false` | identical |
| `dualDecodeArbitration: true` | identical, 3x latency (0.28 s -> 0.91 s) |
| Cohere engine | RTFx 2.79 -> 3.6 s for a 10 s utterance, 1.8 GB |
| Paraformer / SenseVoice | Mandarin-only / no Portuguese |
| Encoder precision | only `int8` and `int4` exist; already on the better one |
| Resampler quality (default 64 vs max 127) | 0.00 dB in 1.5-3.5 kHz, +1.9 dB near Nyquist, transcription unchanged even at quality 0 |
| Audio priming with prior utterance | fixes a plural, overflows the 15 s window, unreliable |

### Vocabulary rescoring: works, and cannot be used

`VocabularyRescorer` is the real mechanism — CTC re-reads the audio under each
word's own timestamps, so a term wins only when the sound supports it. It
recovered `constrangente` -> `constraint` from acoustics alone.

It also produced `acontecer` -> `frontend`, `segundo` -> `mergeado`,
`consideração` -> `constraint`. Net: **-15 WER points for +7 term points, and
0.31 s -> 1.8 s**. Threshold sweeps (0.52 / 0.70 / 0.80 / 0.90, spotter rescue
on and off) moved the numbers around non-monotonically without ever paying off.

The cause is structural, not tuning. The rescorer's acoustic judge is
`FluidInference/parakeet-ctc-110m-coreml`, whose model card declares
`language: ["en"]`. It reads Portuguese audio through a model that has no
Portuguese, so the correct word is not among the candidates and the English
term wins by default. There is no multilingual CTC variant in the library.

### What survived

Input gain. Not a model, not a decoder setting: the microphone was at 13%.
Corrected, the same corpus goes from 84.8% to 94.7% word accuracy, at zero
latency and zero maintenance. It is now applied for the duration of each
recording and restored afterwards.

The dominant remaining error is an English technical term spoken in isolation
(`pull requests` -> `por questões`, `merge` -> `método`). It disappears when the
same term is spoken inside a full sentence, in both engines tested. Structure
disambiguates; nothing else measured here does.

## Option C investigated: a Portuguese CTC as the rescoring judge

The library's rescorer damages Portuguese because its judge declares
`language: ["en"]`. The obvious repair is a judge that knows Portuguese. Tested
with `jonatasgrosman/wav2vec2-large-xlsr-53-portuguese`, a character-level model
that can score any Latin string, English terms included.

**The premise holds, barely.** Scoring only the disputed span, the Portuguese
judge prefers the correct reading in three of four samples:

| sample | wrong reading | correct reading | margin |
|---|---|---|---|
| 04 | `por questões` 15.12 | `pull requests` 14.93 | +1.3% |
| 04-gain70 | `por request` 26.97 | `pull requests` 24.42 | +9.4% |
| 10-live | `por request` 15.37 | `pull requests` 14.89 | +3.1% |
| 11-longa | `por questões` 13.95 | `pull requests` 13.98 | -0.2% |

So the acoustics do carry the distinction — the earlier whole-sentence test
missed it because normalising a twelve-character difference over a hundred and
thirty characters buries it.

**As a rescoring pass it is unusable.** Word spans from Viterbi forced
alignment, candidate terms scored against each span, replacements gated on a
relative margin. Sweeping that margin from 3 to 120:

| margin | WER | terms |
|---|---|---|
| baseline (no pass) | 94.7% | 62% |
| 3 | 25.8% | 85% |
| 15 | 43.7% | 77% |
| 40-95 | 71.6% | 69% |
| 105+ | 94.7% | 62% (never fires) |

The transition is a cliff, not a curve: every operating point that recovers a
term also rewrites `eu não` as `mergeado` and `melhor` as `constraint`. Those
pass a length-ratio gate honestly, and the judge genuinely scores them higher.
Its own free decoding of the same windows is gibberish (`repaz tuws mos`), so at
span granularity its scores are noise, and a 1-9% preference does not survive it.

Two methodological errors made along the way, both caught by measurement: per-
character normalisation hid the signal in the first test, and then favoured long
terms over short words in the second, replacing most of the corpus with
`pull requests`.

**Conclusion.** A stronger judge would need something like MMS-1b — a billion
parameters, larger than the transcription model it is meant to correct, against
a 1 s latency budget the current pipeline meets in 0.31 s. The measured ceiling
stands: 94.7% word accuracy, 62% technical-term recall.

## What actually worked: grammar, not vocabulary

Every mechanism above hands the model *words* — a term list, a replacement
table, a CTC judge scoring candidate spellings. All of them failed. The thing
that worked hands it a *sentence*, and the difference is not a detail.

### The mechanism was closed by a bug

Whisper accepts an initial prompt: text the decoder is conditioned on before it
starts, which is how the industry supplies domain context. WhisperKit exposes it
as `promptTokens` and it returned an empty string, every time, on every version
tried. Instrumenting the decode loop:

```
prefilledIndex=0 initialPromptIndex=25 tokens=25
break at idx=12 isPrefill=true completed=true token=50257 '<|endoftext|>'
```

The decoder forces prompt tokens one index at a time, and the prediction it
makes while doing so is discarded on the next iteration — but
`isSegmentCompleted` honoured it anyway. One `<|endoftext|>` guess at token 12
of 25 ended the segment before decoding began. Two lines fix it:

```swift
(sampleResult.completed && !isPrefill) || …
let isFirstToken = tokenIndex == max(prefilledIndex, initialPromptIndex - 1)
```

Diagnosed here, then found already fixed upstream in
argmaxinc/argmax-oss-swift#514, character for character. Worth noting for the
method: the upstream `main` was never checked before the patch was written.

### An example beats a description

| prompt | technical terms recovered |
|---|---|
| `Sou desenvolvedor e falo de pull requests, merge, deploy.` | 62% |
| `Preciso revisar os pull requests antes do merge.` | 85% |

Whisper conditions on this the way it conditions on the previous window of a
long recording. It wants a sentence it might plausibly have just heard, not a
statement about who is speaking.

### One sentence is the whole of it

Eleven recordings, `large-v3-turbo-compressed`, one line per language:

| examples | accuracy | terms | median | cost |
|---|---|---|---|---|
| none | 87.2% | 50% | 1.34 s | — |
| one sentence | **90.8%** | 86% | 1.33 s | free |
| two | 88.1% | 86% | 1.49 s | +150 ms |
| four | 89.9% | 93% | 1.89 s | +550 ms |
| eight | 89.0% | 86% | 2.41 s | +1070 ms |

The first sentence carries the effect and costs nothing. Four looks best on
terms — one occurrence out of fourteen, noise. Eight is worse on both numbers
and twice as slow, because every prompt token is a decode step taken before the
speech is heard.

### And the vocabulary in it does not matter

| single-line example | accuracy | terms |
|---|---|---|
| sentence with two technical terms | **90.8%** | 86% |
| sentence with four | 89.4% | 86% |
| sentence with eight | 89.9% | 86% |
| **those same eight as a bare list** | **87.2%** | **50%** |
| no example at all | 87.2% | 50% |

Term recall does not move between two terms and eight. The list of the same
eight words scores what no example scores, to the decimal.

So the model is not being given vocabulary. It is being given a sample of how
this speaker builds sentences — which is exactly why every word-list mechanism
in this document returned nothing, and why the surviving failure is a technical
term spoken *in isolation*, outside any sentence. There is no grammar around it
to condition on.

### Language sections are load-bearing

One blob of mixed languages is unsafe in both directions:

| example | pt accuracy | en accuracy |
|---|---|---|
| none | -1.1% | 96.4% |
| Portuguese only | 88.4% | **25.0%** |
| English only | -0.6% | 92.9% |
| both, mixed | 17.7% | 92.9% |
| by section, language detected | **92.3%** | **92.9%** |

A prompt drags the decoder into its own language, so English audio under a
Portuguese example comes back translated. Whisper left to pick for itself does
the same, which is what puts the no-example column in the negative — the fix is
to detect the language once and pin it, not to leave it to the decode loop.

## The engines, on everything this machine recorded

32 recordings, 251 s of speech, production transcribers, 11 with ground truth:

| model | MB | pt accuracy | pt terms | en accuracy | median |
|---|---|---|---|---|---|
| parakeet-tdt-v3 | 461 | **94.7%** | 62% | 85.7% | **0.15 s** |
| whisper-large-v3-turbo | 1620 | 91.1% | **92%** | **96.4%** | 1.69 s |
| whisper-large-v3-turbo-compressed | 632 | 92.1% | **92%** | 92.9% | 1.72 s |
| whisper-small.en | 488 | -3.7% | 54% | 78.6% | 1.85 s |
| whisper-base.en | 145 | -0.5% | 15% | 78.6% | 0.74 s |

Parakeet holds Portuguese accuracy and is eleven times faster; Whisper holds the
technical vocabulary and English. Neither dominates, so both stay selectable.
The English-only models are not usable for this speaker, and are slower than the
multilingual turbo on top of it.

Benchmarking every registered model rather than the one in use is what caught
`whisper-base.en` — the project's recommended default — failing 100% of
transcriptions after language pinning was added, because `detectLangauge` throws
on a single-language model.
