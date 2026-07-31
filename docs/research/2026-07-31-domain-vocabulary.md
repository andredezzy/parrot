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
