# AwaitCue Decision Benchmark

This benchmark freezes human-labeled examples for AwaitCue's two model decisions:

- whether a Hook Condition is `matched`, `notMatched`, or `uncertain`;
- whether the current activity is `interruptible`, `notInterruptible`, or `uncertain`.

It deliberately tests the public decision contract. It does not assert which internal prompt helper,
HTTP library, or model implementation produced the answer.

## Fixed sample set

`benchmark.v1.json` contains 30 synthetic, non-sensitive cases. Every decision label is represented
on both evidence surfaces, and the corpus includes the recurrent ambiguity and focus cases below:

| Decision | Browser DOM + image | App image-only |
|---|---:|---:|
| Condition matched | yes | yes |
| Condition notMatched | yes | yes |
| Condition uncertain | yes | yes |
| Interruptible | yes | yes |
| Not interruptible | yes | yes |
| Interruptibility uncertain | yes | yes |

Condition regression scenarios include overall failure with a locally successful target, duplicate
same-name nodes with conflicting states, Condition text visible inside an input field, explicit
failure, queued/running work, and missing status. Interruptibility scenarios include meetings,
full-screen presentations, active document writing, production debugging, ordinary article reading,
idle chat reading, and mixed-window focus that cannot be identified reliably.

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

1. Create a synthetic screenshot in `fixtures/source/` and its PNG under `fixtures/images/`.
2. For browser evidence, add a short, selected-region DOM fixture under `fixtures/dom/`.
3. Add one human label to `benchmark.v1.json` before running the model.
4. Add both browser DOM+image and app image-only variants when introducing a new semantic scenario.
5. Run the offline tests and review the image manually.

Do not add real customer pages, internal dashboards, private messages, window titles, full URLs, or
captured user desktops to the repository.
