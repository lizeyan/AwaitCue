# AwaitCue Decision Benchmark

This benchmark freezes human-labeled examples for AwaitCue's two model decisions:

- whether a Hook Condition is `matched`, `notMatched`, or `uncertain`;
- whether the current activity is `interruptible`, `notInterruptible`, or `uncertain`.

It deliberately tests the public decision contract. It does not assert which internal prompt helper,
HTTP library, or model implementation produced the answer.

## Fixed sample set

`benchmark.v1.json` contains 35 synthetic, non-sensitive cases, including 16 human-labeled
Appropriate to Interrupt cases. The evidence surface follows the production path instead of
creating a symmetric but artificial matrix:

| Decision | Browser Target DOM-only | App Target image-only | Active-window screenshot + activity summary |
|---|---:|---:|---:|
| Condition matched | yes | yes | no |
| Condition notMatched | yes | yes | no |
| Condition uncertain | yes | yes | no |
| Interruptible | no | no | yes |
| Not interruptible | no | no | yes |
| Interruptibility uncertain | no | no | yes |

Condition regression scenarios include overall failure with a locally successful target, duplicate
same-name nodes with conflicting states, horizontally expanded browser evidence containing adjacent
conflicting states, a pending deployment expressed by real page hierarchy and full class values,
Condition text visible inside an input field, explicit failure, queued/running work, and missing
status. Interruptibility scenarios include meetings, full-screen presentations, active document
writing, production debugging, ordinary article reading, idle chat reading, waiting for automated
work, email and settings reading, passive music, spreadsheet editing, chat drafting, form filling,
full-screen video, and mixed all-in-one app focus that cannot be identified reliably. Every
interruption case includes a short human judgment rationale in the manifest and final report. The
browser Condition
case for `no_semantic_content` freezes the production behavior and requires `uncertain` instead of
guessing a Canvas or pure-image state. Appropriate to Interrupt always uses the current frontmost
window screenshot, even when that window belongs to a browser; it never uses Browser Target DOM.

The PNGs are generated from the checked-in SVG sources. They contain no user screenshots, internal
URLs, accounts, API keys, or company data. Labels are independent literals defined by the scenario,
not recomputed from model output.

## Offline validation

Run fixture integrity, manifest, request-contract, response-classification, and metric tests:

```bash
node --test Benchmarks/Decision/tests/*.test.mjs
node Scripts/run-decision-benchmark.mjs --dry-run
```

These commands are safe for CI and never call a model.

## Live benchmark

The live adapter accepts any OpenAI Responses-compatible endpoint. Keep credentials outside the
repository and shell scripts:

```bash
export AWAITCUE_BASE_URL="https://provider.example/v1"
export AWAITCUE_MODEL="vision-decision-model"
read -rs AWAITCUE_API_KEY
export AWAITCUE_API_KEY

node Scripts/run-decision-benchmark.mjs \
  --repetitions 5 \
  --output /tmp/awaitcue-decision-report.json
```

Live runs are intentionally not part of required GitHub CI: they cost tokens, depend on an external
provider, and measure nondeterministic behavior. CI verifies that the fixed corpus and scoring logic
remain valid. Release candidates should run the live benchmark separately.

`latencyMs` measures the complete non-streaming request through response-body read, JSON decoding,
and decision classification. This path does not expose first-token events, so it intentionally does
not invent TTFT or TPOT from the end-to-end duration. Responses usage still reports input, output,
reasoning, cached-input, and cache-write tokens when the configured provider returns those fields.

On a Mac where AwaitCue already has a saved model configuration, run only the interruption corpus
without copying credentials into the shell history:

```bash
Scripts/run-local-interruptibility-benchmark.sh --repetitions 5
```

The script reads the same Base URL, model name, and Keychain item as AwaitCue. It stores the JSON
report under the Git-ignored `.local/benchmarks/` directory. The App and benchmark also load the
same interruptibility prompt from `Sources/AwaitCueModel/Resources/interruptibility.txt`, so the
score represents the shipped decision contract rather than a benchmark-only prompt.

## Human review standard

Freeze these rules before opening any locally captured images or model answers:

- Judge the visible activity and the valid input-activity summary together. An application name by
  itself is never enough, especially for browsers, chat clients, and other all-in-one apps.
- Use `notInterruptible` for work that visibly needs continuous attention, including drafting,
  coding, debugging, editing a document or spreadsheet, filling a form, a meeting, or presenting.
- Use `interruptible` for passive reading, browsing, listening, or waiting when no focused input or
  time-sensitive interaction is visible. Ordinary article reading is intentionally interruptible.
- Use `uncertain` only when the captured evidence cannot identify the current activity reliably or
  shows genuinely conflicting activities. Do not guess from content outside the captured frame.
- Recent-input seconds are supporting evidence, not a decision rule. Samples before the recorded
  activity-validity boundary display that value as unavailable.
- Label every sample from the review manifest before opening model decisions, confidence, errors, or
  latency. Privacy-excluded windows produce no review image and must never be reconstructed.
- Keep each rationale at the activity level, such as drafting, passive reading, or waiting. Do not
  copy window titles, URLs, account names, people, message text, document text, or other visible
  content into the rationale, even though the local review and report files are Git-ignored.

The production evidence adapter checks excluded application bundle identifiers and browser hosts
before requesting any ScreenCaptureKit window list or image. If browser-host exclusions are
configured but the extension cannot identify the active host unambiguously, capture is skipped
conservatively. The 24-hour collector records an excluded poll without creating a sample or calling
the model.

After a 24-hour local sampling run has reached `completed`, generate the human-review file before
looking at any model answers:

```bash
Scripts/review-local-interruptibility-benchmark.mjs prepare \
  --run-directory .local/benchmarks/<run> \
  --output .local/benchmarks/<run>/human-review.json
```

The command refuses a running run, a planned duration shorter than 24 hours, a run marked completed
before `intendedEndAt`, an incomplete sample set, a sample outside the planned sampling window, or
capture times that move backwards across consecutive sample IDs. The review output must be stored
directly in the benchmark run directory because its image references are intentionally relative to
that private evidence root. The generated file contains the local image
path, capture time, limited activity summary, image SHA-256, opaque SHA-256 anchors for the original
run and sample JSON bytes, and blank `humanDecision` /
`humanRationale` fields; it deliberately excludes the model decision, confidence, latency, and
error. New samples record the digest when the model input is captured. Legacy samples without that
field are clearly counted as having a review-preparation digest instead of being presented as
capture-time verified. Review every image and record one of `interruptible`, `notInterruptible`, or
`uncertain` plus an independent rationale through the CLI instead of editing JSON manually:

```bash
Scripts/review-local-interruptibility-benchmark.mjs next \
  --review .local/benchmarks/<run>/human-review.json

Scripts/review-local-interruptibility-benchmark.mjs label \
  --review .local/benchmarks/<run>/human-review.json \
  --id 0001 \
  --decision notInterruptible \
  --rationale '正在编辑技术内容，需要持续专注。'
```

`next` returns only the next incomplete sample's ID, capture time, limited activity summary, and
absolute image path. It rechecks the private file boundary and image SHA-256 before displaying that
evidence, and never reads the original sample JSON that contains the model answer. `label` atomically
replaces the private review file, preserves mode `0600`, and refuses to overwrite an already or
partially labeled sample. Its stdout contains only the labeled sample ID. Progress can be checked
between review sessions without opening any model data:

```bash
Scripts/review-local-interruptibility-benchmark.mjs status \
  --review .local/benchmarks/<run>/human-review.json
```

`status` returns the total, completed and remaining counts, completed-label distribution, and next
incomplete sample ID. It does not print activity summaries, image paths, or any model field. Then
produce the comparison report:

```bash
Scripts/review-local-interruptibility-benchmark.mjs report \
  --run-directory .local/benchmarks/<run> \
  --review .local/benchmarks/<run>/human-review.json \
  --output .local/benchmarks/<run>/comparison-report.json
```

After every human label is frozen, a candidate prompt can be replayed once against the exact same
private evidence. The command reads the model configuration and Keychain item already saved by
AwaitCue; neither the key nor raw evidence is copied into the report:

```bash
Scripts/replay-local-interruptibility-benchmark.sh \
  --run-directory .local/benchmarks/<run> \
  --review .local/benchmarks/<run>/human-review.json \
  --prompt .local/benchmarks/candidate-interruptibility.txt \
  --output .local/benchmarks/<run>/candidate-replay.json
```

Replay refuses a running or shortened run, incomplete human labels, changed run/sample/image bytes,
non-private evidence, symbolic or additional hard links, and output paths that alias an input. Each
image digest is checked again immediately before the request. The private `0600` report contains
only labels, model decisions, confidence, stable error categories, end-to-end latency, aggregate
usage, and accuracy; it omits activity context, image paths, and image digests. Because each real
screen state is replayed once, stability metrics remain `null` instead of claiming artificial 100%
stability. `pairedComparison` reports samples that the candidate fixed or regressed instead of
letting opposite changes cancel inside one accuracy number. `promptVerifiedPairedComparison`
repeats that comparison only from the baseline prompt's recorded validity boundary, so legacy
samples are not misattributed to the current production prompt. Run and sample record digests stay
inside the review plan for integrity checks and are not copied into the replay report.

The run and samples directories must keep their private `0700` boundary. Original `run.json`,
sample JSON, and JPEG inputs must also remain regular files with no group or other permissions;
review preparation refuses evidence whose directory or file permissions were widened or whose
contents have an additional hard-link alias outside the canonical run layout.
Both generated files are forced to mode `0600`, the report refuses a human-review file whose
permissions were widened, and output paths are opened without following symbolic links. Neither
command permits its output path to replace any `run.json`, sample JSON, JPEG, or human-review input
that it read for the operation. Non-exclusive report output is opened without truncation first; its
device and inode are checked against every input before the file is truncated and rewritten.
The report is rejected if a sample is missing, duplicated,
not numbered continuously from `0001`, has a JSON filename / sample ID / image filename mismatch,
is rebound to another image, changes bytes after review preparation, disagrees with a digest recorded at
capture time, changes its original sample JSON after review preparation, changes its review-time
activity context, or lacks either a human decision or rationale. The opaque sample-record anchor is
used only for this comparison and is not copied into the final report. The run-record anchor likewise
prevents prompt boundaries, timing, and reliability counters from changing between `prepare` and
`report` without revealing additional run content.
Model-failure samples must not also claim a decision or confidence; successful samples require a
contract-valid decision, `0...1` confidence, and a non-negative integer end-to-end latency.
Per-sample model errors in the comparison report are normalized to stable categories such as
`transport`, `http_status`, and `incomplete_response`. Legacy Swift error descriptions and unknown
strings are never copied verbatim because their associated values may contain a service-provided
reason or other diagnostic detail.
The report separately states how many
images were verified from capture time and how many legacy images were anchored only when review
preparation began. Only the report phase reads the original model answers and computes accuracy,
confusion, failures, and latency.

The comparison report intentionally omits `contextText`, `imageFile`, and the image digest itself.
It retains only aggregate integrity counts and whether each sample had a capture-time digest, so the
report cannot become a second copy of the raw local evidence. It also retains the four-digit
`activityEvidenceValidFromSampleID` boundary so readers know which early samples had no trustworthy
recent-input summary. `samplingTimeline` reports the first and last capture, the delay from run
start, the remaining gap before the intended end, the observed sample span, and nearest-rank p50 /
p95 / maximum adjacent-sample gaps. These fields make long collection outages visible without
copying any screen content into the report. Human-review preparation requires every sample capture
and the final evidence-attempt timestamp to remain within the planned sampling window; model work
may finish after the deadline, but a new screen read cannot begin after it. The run also records the
SHA-256 of the normalized production Appropriate to Interrupt prompt and the first sample ID for
which that digest is known.
Resuming a run with a different recorded digest is rejected instead of silently mixing prompt
versions into one accuracy number. The digest and validity boundary must be present together and
well-formed; `evidenceIntegrity.promptVerifiedSampleCount` reports how many reviewed samples fall
inside that recorded prompt range. `promptVerifiedSummary` repeats the benchmark metrics for only
those samples, while `summary` continues to describe the complete 24-hour corpus including legacy
evidence.

`confidenceSummary` reports the number and mean confidence of contract-valid decisions, then splits
the mean between decisions that matched the blind human label and decisions that did not. It uses no
arbitrary confidence threshold; model failures have no decision or confidence and stay visible in
the ordinary accuracy/error metrics instead.

Each local screen context is evaluated only once, so the report cannot measure repeated-run
stability for those samples. `meanCaseStability`, `fullyStableCaseRate`, and per-case `stability` are
therefore `null` rather than a misleading 100%. The 24-hour collector also does not persist token
usage, so local-report `tokens` is `null` rather than a fabricated all-zero usage record. The separate
fixed benchmark continues to report real repeated-run stability and token/cache metrics when its
Responses endpoint supplies them.

Run reliability counters distinguish locked sessions, local privacy exclusions, temporarily
unavailable frontmost windows, screenshot-system failures, and model failures. Runs migrated from an
older collector include `availabilityClassificationValidFrom`; capture-failure counts before that
timestamp may include unavailable-window polls and are intentionally retained rather than rewritten.
The final comparison report also preserves `lastEvidenceAttemptAt` so the run's final sampling
boundary can be audited without opening any model-answer fields. Human-review preparation rejects
this timestamp when it falls outside the planned sampling window or precedes the final recorded
sample; a run cannot therefore claim a final evidence attempt that contradicts its own sampling timeline.
The collector also persists the last ScreenCaptureKit evidence-attempt time before making the
request. Successful samples, duplicate frames, unavailable windows, and capture failures therefore
all wait for the full sample interval, including across collector restarts; the one-minute health
poll does not silently become one screenshot attempt per minute.

Maintainers can also run the manual **Decision benchmark** GitHub Actions workflow after configuring
the `AWAITCUE_BENCHMARK_BASE_URL`, `AWAITCUE_BENCHMARK_API_KEY`, and
`AWAITCUE_BENCHMARK_MODEL` repository secrets. The workflow uploads the aggregate JSON report and
enforces the requested accuracy and stability thresholds without exposing raw evidence or secrets.

To compare a different model or prompt without changing the corpus:

```bash
node Scripts/run-decision-benchmark.mjs \
  --model another-model \
  --condition-prompt /tmp/condition-v2.txt \
  --interruptibility-prompt /tmp/interruptibility-v2.txt \
  --repetitions 5 \
  --minimum-accuracy 0.90 \
  --minimum-stability 0.90
```

The process exits with status 2 when overall accuracy is below the configured gate, or status 3 when
mean per-case stability is below its gate.

## Report semantics

- `accuracy`: correct runs divided by all runs. Incomplete, invalid, and transport errors count as
  incorrect instead of disappearing from the denominator.
- `validDecisionAccuracy`: correct runs divided only by runs containing a contract-valid decision.
- `meanCaseStability`: for each case, the most frequent outcome divided by repetitions, averaged
  across cases. Failures are outcomes, so repeated invalid responses are visible rather than hidden.
- `fullyStableCaseRate`: fraction of cases whose repeated outcomes were identical.
- `confusion`: artificial label versus actual decision, including `incomplete`, `invalid`, and
  `error` buckets.
- `latencyMs`: nearest-rank p50, p95, and maximum end-to-end request time.
- `tokens`: total input, output, hidden reasoning, cached input, and cache-write tokens, plus request
  and token cache hit rates.

Reports contain aggregate metrics and decisions, not raw screenshot bytes, DOM text, or API keys.
The endpoint is reduced to its hostname.

## Adding a case

1. For a Browser Condition case, add only a short selected-region sanitized HTML fixture under
   `fixtures/dom/`; browser Condition cases must never reference an image. Match production by
   keeping the relevant hierarchy, visible text, complete `class`, ARIA, `data-*`, and relative
   `data-awaitcue-rect` attributes. Do not flatten classes into a local status vocabulary or add
   page-specific interpretation outside the fixture.
2. For an App Condition case, create a synthetic screenshot in `fixtures/source/` and its PNG under
   `fixtures/images/`; App Condition cases must not add DOM text.
3. For an Appropriate to Interrupt case, add an `active-window` synthetic screenshot and the same
   short app/title/recent-input summary used by production. Do not add a DOM variant: production
   captures the frontmost window for this decision, including browser windows.
4. Add one human label to `benchmark.v1.json` before running the model.
5. Add both browser DOM-only and app image-only Condition variants when the semantic scenario applies
   to both surfaces. Browser-specific evidence insufficiency cases do not need a fake App variant.
6. Run the offline tests and review the image manually.

Do not add real customer pages, internal dashboards, private messages, window titles, full URLs, or
captured user desktops to the repository.
