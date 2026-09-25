# noisemaker-for-perl: compatibility report

## 1. Source and authority revisions

Daily review: 2026-09-25. Current inspected source: [`5cf1b4e462f2865ff85fa043af0e005a3a8b7ee6`](https://github.com/noisefactorllc/noisemaker-for-perl/commit/5cf1b4e462f2865ff85fa043af0e005a3a8b7ee6).
Full rendered parity remains **unverified** (the current bounded gate also has failures). No release approval or new closure follows from this review.
Current upstream discovery: `bbdeb56c4b75cf33379766c3e87b0f5a18bcbba8`. Published Noisemaker authority: `1.0.179`, source `fca611fd8f91424661d4e531d39313d24ea21134`, 210 effect IDs.
The observations below retain their original source and authority identities. They do not qualify later updates.
Current served kit: `0.1.13`, source `bf02783236fdfa3d5cfb9dce64e32400a6ba61d4`. [Retrieved inventory and hashes](/Users/alex/.codex/automations/noisemaker-port-completion-audit/review-20260925-053200/current-served-inventories.json). Artifact identity does not establish host qualification.

### Earlier source observations

Date: 2026-09-25 UTC. Reviewed source: [`bf02783236fdfa3d5cfb9dce64e32400a6ba61d4`](https://github.com/noisefactorllc/noisemaker-for-perl/commit/bf02783236fdfa3d5cfb9dce64e32400a6ba61d4).
Local and remote `main` matched. All tracked file hashes matched before report edits.
This audit changes only the two requested reports. It does not advance implementation or the parity checkpoint.
The audit completed with gaps. Full parity and release readiness remain unqualified.
The containing commit publishes these reports. The shared result records remote verification.

The port supports offline CPU rendering through Perl APIs, CLI commands, and a standalone export kit.
The documented minimum is Perl 5.22. Windows and 32-bit Perl remain outside the documented CI matrix.
[Contract](https://github.com/noisefactorllc/noisemaker-for-perl/blob/bf02783236fdfa3d5cfb9dce64e32400a6ba61d4/README.md).

CPU authority: `749aa116730d2b294f940390a842d5d8ab5824d7`, also the current CPU head.
Its runtime SHA-256 is `f188fbae51f369037babb6a3b06c7c9ec58a8c018fdcc3c89b17e1c97b316663`.
Pinned upstream: `13fa8b54002539df71ceffa34b4d894cb0a4573d`. Published engine: `1.0.177`.
Current upstream: `aa96726ddb542a03d0b58cbad2af206fba40e7fe`.
The four intervening commits change six documentation or website files. They do not change renderer inputs.
[Authority delta](/Users/alex/.codex/automations/noisemaker-port-completion-audit/evidence-audit-20260925-010210/upstream-delta.json). [Oracle lock](https://github.com/noisefactorllc/noisemaker-for-perl/blob/bf02783236fdfa3d5cfb9dce64e32400a6ba61d4/scripts/oracle-lock.json).

Served kit `0.1.13` identifies the reviewed source. All 324 files match their hashes and a local reproduction.
All 319 served engine files match this source. Both MIT notices are present.
[Immutable metadata](https://kits.noisedeck.app/perl/0.1.13/deployment-meta.json). [Artifact verification](/Users/alex/.codex/automations/noisemaker-port-completion-audit/evidence-audit-20260925-010210/artifact-verification.json).

Evidence is fresh for the stated CPU probes and distribution bytes. Full current parity remains unverified.
Later runtime, package, or authority changes require new source-bound checks.

## 2. Host and distribution matrix

Current tests and qualification limits are in [section 3](#3-parity-coverage).
The matrix below retains the earlier measured scope. A historical verified row is not a current-source or full-platform certification.

| Dimension | Status | Measured scope or limit |
|---|---|---|
| macOS arm64, Perl 5.34.1 | verified | 909 assertions. Installed CLI, API, media, animation, errors, recovery, cancellation, and private removal. |
| Linux Perl 5.22 and 5.42 | verified | Exact-source CI source and packaged tests. External oracle file skips in these matrix jobs. |
| macOS Perl 5.42 | verified | Exact-source CI source and packaged tests. External oracle file skips. |
| Current Perl 5.44 | unverified | No local or exact-source CI execution. |
| Windows, 32-bit Perl, alternative floating-point configurations | unverified | No qualification evidence. |
| Candidate module 1.000 installation | verified | Built archive installs privately and supports README CLI and API examples. |
| Served kit 0.1.13 | verified | 324 file hashes, local reproduction, 319 source matches, notices, output, diagnostics, and recovery. |
| CPAN module 1.000 | unverified | Registry discovery still returns historical 0.105. No GitHub release exists. |
| Upgrade from 0.105 | unverified | README declares incompatible APIs. No migration run. |
| Sustained resources and broad host lifecycle | unverified | Bounded process exit and cancellation do not qualify sustained operation. |
| Four-component solid color | failed | Separate alpha differs from the CPU reference. GAP-004. |
| Landscape filtering parameter | failed | Perl rejects the current parameter. GAP-005. |
| Full parity and release readiness | blocked | Exclusions, missing effects, parameter failures, and remaining platform qualification. |

No GUI is present. GUI keyboard, focus, and label checks do not apply.
The audit exercised installed CLI help, progress, diagnostics, and cancellation.

## 3. Parity coverage

### Daily review, 2026-09-25

The four-component solid color defect reproduces at the current source. With color alpha 0.3 and explicit alpha 0.8, the output alpha is 61 instead of the retained reference value 204. Omitting explicit alpha produces 76 instead of 255. The original 167 exact default cases, 38 exclusions, and five missing effect IDs do not qualify full parity. [Raw evidence](/Users/alex/.codex/automations/noisemaker-port-completion-audit/review-20260925-053200/perl-alpha-current.json).

The current full case denominator remains incomplete. Missing parameters, hosts, external inputs, and stateful sequences remain qualification gaps. No skip or tolerated difference counts as exact parity.

### Earlier measurements

RGBA8 byte equality is the strict comparison rule. No tolerance or golden changed.
Full parity requires complete coverage with no skipped or missing cases.
Unknown denominators remain `not measured`.

| Gate | Expected | Executed | Strict passes | Mismatches | Errors | Skips or missing |
|---|---|---|---|---|---|---|
| Existing default effect sweep | 205 port IDs | 167 | 167 | 0 | 0 | 38 excluded IDs |
| Upstream effect IDs | 210 IDs | 167 defaults | 167 | 0 | 0 | 38 excluded, five absent |
| Independent nondefault 16×12 probes | 4 | 4 | 3 | 1 | 0 | 0 |
| Controlled solid DSL follow-ups | 3 | 3 | 1 | 2 | 0 | 0 |
| External media 32×32 comparison | 1 | 1 | 1 | 0 | 0 | 0 |
| Complete parameter and state matrix | not measured | incomplete | not measured | alpha failures | landscape rejection | not measured |

The sweep uses size 8×8, seed 1, time 0.25, and default parameters.
The independent probes use size 16×12, seed 7, time 0.7, and recorded nondefault parameters.
Default passes do not qualify all parameter choices. Additional probes overlap effects and do not increase the unique effect denominator.
`t/05-parity.t` separately permits delta two for one Navier-Stokes assertion. That tolerant assertion does not count as strict equality.

Current served declaration: 205 effect IDs. This inventory is not evidence of execution. The declaration column below reflects kit `0.1.13`.

### Effect inventory

| Effect ID | Default sweep status | Full current qualification |
|---|---|---|
| `classicNoisedeck/bitEffects` | verified: exact default comparison | unverified |
| `classicNoisedeck/caustic` | verified: exact default comparison | unverified |
| `classicNoisedeck/cellNoise` | verified: exact default comparison | unverified |
| `classicNoisedeck/cellRefract` | verified: exact default comparison | unverified |
| `classicNoisedeck/coalesce` | verified: exact default comparison | unverified |
| `classicNoisedeck/colorLab` | verified: exact default comparison | unverified |
| `classicNoisedeck/composite` | verified: exact default comparison | unverified |
| `classicNoisedeck/effects` | verified: exact default comparison | unverified |
| `classicNoisedeck/fractal` | verified: exact default comparison | unverified |
| `classicNoisedeck/glitch` | verified: exact default comparison | unverified |
| `classicNoisedeck/kaleido` | verified: exact default comparison | unverified |
| `classicNoisedeck/lensDistortion` | verified: exact default comparison | unverified |
| `classicNoisedeck/moodscape` | verified: exact default comparison | unverified |
| `classicNoisedeck/noise` | verified: exact default comparison | unverified |
| `classicNoisedeck/noise3d` | verified: exact default comparison | unverified |
| `classicNoisedeck/refract` | verified: exact default comparison | unverified |
| `classicNoisedeck/shapeMixer` | verified: exact default comparison | unverified |
| `classicNoisedeck/shapes` | verified: exact default comparison | unverified |
| `classicNoisedeck/shapes3d` | verified: exact default comparison | unverified |
| `classicNoisedeck/splat` | verified: exact default comparison | unverified |
| `filter/adjust` | verified: exact default comparison | unverified |
| `filter/bloom` | verified: exact default comparison | unverified |
| `filter/blur` | verified: exact default comparison | unverified |
| `filter/bulge` | verified: exact default comparison | unverified |
| `filter/celShading` | verified: exact default comparison | unverified |
| `filter/channel` | verified: exact default comparison | unverified |
| `filter/chroma` | verified: exact default comparison | unverified |
| `filter/chromaticAberration` | verified: exact default comparison | unverified |
| `filter/chrome` | verified: exact default comparison | unverified |
| `filter/clouds` | verified: exact default comparison | unverified |
| `filter/colorReplace` | verified: exact default comparison | unverified |
| `filter/convolutionFeedback` | excluded: iterated | unverified |
| `filter/corrupt` | verified: exact default comparison | unverified |
| `filter/craquelure` | verified: exact default comparison | unverified |
| `filter/crt` | verified: exact default comparison | unverified |
| `filter/degauss` | verified: exact default comparison | unverified |
| `filter/deriv` | verified: exact default comparison | unverified |
| `filter/directionalBlur` | verified: exact default comparison | unverified |
| `filter/dither` | verified: exact default comparison | unverified |
| `filter/edge` | verified: exact default comparison | unverified |
| `filter/emboss` | verified: exact default comparison | unverified |
| `filter/extrude` | verified: exact default comparison | unverified |
| `filter/feedback` | excluded: iterated | unverified |
| `filter/fibers` | verified: exact default comparison | unverified |
| `filter/flipMirror` | verified: exact default comparison | unverified |
| `filter/fxaa` | verified: exact default comparison | unverified |
| `filter/glowingEdge` | verified: exact default comparison | unverified |
| `filter/glyphMap` | verified: exact default comparison | unverified |
| `filter/grade` | verified: exact default comparison | unverified |
| `filter/grain` | verified: exact default comparison | unverified |
| `filter/grime` | verified: exact default comparison | unverified |
| `filter/halftone` | verified: exact default comparison | unverified |
| `filter/hatch` | verified: exact default comparison | unverified |
| `filter/highPass` | verified: exact default comparison | unverified |
| `filter/historicPalette` | verified: exact default comparison | unverified |
| `filter/invert` | verified: exact default comparison | unverified |
| `filter/lens` | verified: exact default comparison | unverified |
| `filter/lensFlare` | verified: exact default comparison | unverified |
| `filter/lensWarp` | verified: exact default comparison | unverified |
| `filter/lightLeak` | verified: exact default comparison | unverified |
| `filter/lighting` | verified: exact default comparison | unverified |
| `filter/lowPoly` | verified: exact default comparison | unverified |
| `filter/median` | verified: exact default comparison | unverified |
| `filter/morphology` | verified: exact default comparison | unverified |
| `filter/mosaicTiles` | verified: exact default comparison | unverified |
| `filter/motionBlur` | excluded: iterated | unverified |
| `filter/normalMap` | verified: exact default comparison | unverified |
| `filter/normalize` | verified: exact default comparison | unverified |
| `filter/octaveWarp` | verified: exact default comparison | unverified |
| `filter/oilPaint` | verified: exact default comparison | unverified |
| `filter/osd` | verified: exact default comparison | unverified |
| `filter/outline` | verified: exact default comparison | unverified |
| `filter/palette` | verified: exact default comparison | unverified |
| `filter/parallax` | verified: exact default comparison | unverified |
| `filter/patchwork` | verified: exact default comparison | unverified |
| `filter/photocopy` | verified: exact default comparison | unverified |
| `filter/pinch` | verified: exact default comparison | unverified |
| `filter/pixelSort` | verified: exact default comparison | unverified |
| `filter/pixels` | verified: exact default comparison | unverified |
| `filter/plasticWrap` | verified: exact default comparison | unverified |
| `filter/polar` | verified: exact default comparison | unverified |
| `filter/pondRipples` | verified: exact default comparison | unverified |
| `filter/posterize` | verified: exact default comparison | unverified |
| `filter/prismaticAberration` | verified: exact default comparison | unverified |
| `filter/reindex` | verified: exact default comparison | unverified |
| `filter/relief` | verified: exact default comparison | unverified |
| `filter/repeat` | verified: exact default comparison | unverified |
| `filter/reverb` | verified: exact default comparison | unverified |
| `filter/ridge` | verified: exact default comparison | unverified |
| `filter/rotate` | verified: exact default comparison | unverified |
| `filter/scale` | verified: exact default comparison | unverified |
| `filter/scanlineError` | verified: exact default comparison | unverified |
| `filter/scatter` | verified: exact default comparison | unverified |
| `filter/scratches` | verified: exact default comparison | unverified |
| `filter/scroll` | verified: exact default comparison | unverified |
| `filter/seamless` | verified: exact default comparison | unverified |
| `filter/sharpen` | verified: exact default comparison | unverified |
| `filter/simpleAberration` | verified: exact default comparison | unverified |
| `filter/sine` | verified: exact default comparison | unverified |
| `filter/skew` | verified: exact default comparison | unverified |
| `filter/smooth` | verified: exact default comparison | unverified |
| `filter/smoothstep` | verified: exact default comparison | unverified |
| `filter/snow` | verified: exact default comparison | unverified |
| `filter/sobel` | verified: exact default comparison | unverified |
| `filter/spatter` | verified: exact default comparison | unverified |
| `filter/spinBlur` | verified: exact default comparison | unverified |
| `filter/spiral` | verified: exact default comparison | unverified |
| `filter/spookyTicker` | verified: exact default comparison | unverified |
| `filter/stamp` | verified: exact default comparison | unverified |
| `filter/step` | verified: exact default comparison | unverified |
| `filter/stipple` | verified: exact default comparison | unverified |
| `filter/strayHair` | verified: exact default comparison | unverified |
| `filter/strokes` | verified: exact default comparison | unverified |
| `filter/temporalAberration` | excluded: iterated | unverified |
| `filter/tetraColorArray` | verified: exact default comparison | unverified |
| `filter/tetraCosine` | verified: exact default comparison | unverified |
| `filter/text` | verified: exact default comparison | unverified |
| `filter/texture` | verified: exact default comparison | unverified |
| `filter/threshold` | verified: exact default comparison | unverified |
| `filter/tile` | verified: exact default comparison | unverified |
| `filter/tint` | verified: exact default comparison | unverified |
| `filter/translate` | verified: exact default comparison | unverified |
| `filter/tunnel` | verified: exact default comparison | unverified |
| `filter/unsharpMask` | verified: exact default comparison | unverified |
| `filter/vaseline` | verified: exact default comparison | unverified |
| `filter/vignette` | verified: exact default comparison | unverified |
| `filter/warp` | verified: exact default comparison | unverified |
| `filter/watercolor` | verified: exact default comparison | unverified |
| `filter/waves` | verified: exact default comparison | unverified |
| `filter/wind` | verified: exact default comparison | unverified |
| `filter/wobble` | verified: exact default comparison | unverified |
| `filter/wormhole` | verified: exact default comparison | unverified |
| `filter/zoomBlur` | verified: exact default comparison | unverified |
| `filter3d/flow3d` | excluded: iterated | unverified |
| `filter3d/palette3d` | excluded: typed | unverified |
| `mixer/alphaMask` | verified: exact default comparison | unverified |
| `mixer/applyMode` | verified: exact default comparison | unverified |
| `mixer/blendMode` | verified: exact default comparison | unverified |
| `mixer/cellSplit` | verified: exact default comparison | unverified |
| `mixer/centerMask` | verified: exact default comparison | unverified |
| `mixer/channelCombine` | verified: exact default comparison | unverified |
| `mixer/distortion` | verified: exact default comparison | unverified |
| `mixer/focusBlur` | verified: exact default comparison | unverified |
| `mixer/mashup` | verified: exact default comparison | unverified |
| `mixer/patternMix` | verified: exact default comparison | unverified |
| `mixer/shadow` | verified: exact default comparison | unverified |
| `mixer/shapeMask` | verified: exact default comparison | unverified |
| `mixer/split` | verified: exact default comparison | unverified |
| `mixer/thresholdMix` | verified: exact default comparison | unverified |
| `mixer/uvRemap` | verified: exact default comparison | unverified |
| `points/attractor` | excluded: iterated | unverified |
| `points/buddhabrot` | excluded: iterated | unverified |
| `points/dla` | excluded: iterated | unverified |
| `points/flock` | excluded: iterated | unverified |
| `points/flow` | excluded: iterated | unverified |
| `points/heightGrid` | verified: exact default comparison | unverified |
| `points/hydraulic` | excluded: iterated | unverified |
| `points/lenia` | excluded: iterated | unverified |
| `points/life` | excluded: iterated | unverified |
| `points/physarum` | excluded: iterated | unverified |
| `points/physical` | excluded: iterated | unverified |
| `render/loopBegin` | excluded: iterated | unverified |
| `render/loopEnd` | excluded: typed | unverified |
| `render/meshLoader` | missing from port | unverified |
| `render/meshRender` | missing from port | unverified |
| `render/pointsBillboardRender` | excluded: iterated | unverified |
| `render/pointsEmit` | excluded: iterated | unverified |
| `render/pointsRender` | excluded: iterated | unverified |
| `render/render3d` | excluded: typed | unverified |
| `render/renderCubemap3d` | excluded: typed | unverified |
| `render/renderCubemapSurface` | excluded: typed | unverified |
| `render/renderLandscape3d` | excluded: typed | failed: GAP-005 |
| `render/renderLit3d` | excluded: typed | unverified |
| `synth/bitwise` | verified: exact default comparison | unverified |
| `synth/cell` | verified: exact default comparison | unverified |
| `synth/cellularAutomata` | excluded: iterated | unverified |
| `synth/curl` | verified: exact default comparison | unverified |
| `synth/gabor` | verified: exact default comparison | unverified |
| `synth/gradient` | verified: exact default comparison | unverified |
| `synth/julia` | verified: exact default comparison | unverified |
| `synth/mandala` | verified: exact default comparison | unverified |
| `synth/mandelbrot` | verified: exact default comparison | unverified |
| `synth/media` | verified: exact default comparison | unverified |
| `synth/mnca` | excluded: iterated | unverified |
| `synth/modPattern` | verified: exact default comparison | unverified |
| `synth/navierStokes` | excluded: iterated | unverified |
| `synth/newton` | verified: exact default comparison | unverified |
| `synth/noise` | verified: exact default comparison | unverified |
| `synth/osc2d` | verified: exact default comparison | unverified |
| `synth/pattern` | verified: exact default comparison | unverified |
| `synth/perlin` | verified: exact default comparison | unverified |
| `synth/polygon` | verified: exact default comparison | unverified |
| `synth/reactionDiffusion` | excluded: iterated | unverified |
| `synth/remap` | verified: exact default comparison | unverified |
| `synth/roll` | missing from port | unverified |
| `synth/sacredGeometry` | verified: exact default comparison | unverified |
| `synth/scope` | missing from port | unverified |
| `synth/shape` | verified: exact default comparison | unverified |
| `synth/solid` | verified: exact default comparison | failed: GAP-004 |
| `synth/spectrum` | missing from port | unverified |
| `synth/subdivide` | verified: exact default comparison | unverified |
| `synth/testPattern` | verified: exact default comparison | unverified |
| `synth3d/cell3d` | excluded: typed | unverified |
| `synth3d/cellularAutomata3d` | excluded: iterated | unverified |
| `synth3d/flythrough3d` | excluded: typed | unverified |
| `synth3d/fractal3d` | excluded: typed | unverified |
| `synth3d/heightmap3d` | excluded: typed | unverified |
| `synth3d/noise3d` | excluded: typed | unverified |
| `synth3d/reactionDiffusion3d` | excluded: iterated | unverified |
| `synth3d/shape3d` | excluded: typed | unverified |

## 4. Evidence

Review CI boundary: No workflow run exists at the inspected source SHA. The preceding runtime source bf02783236fdfa3d5cfb9dce64e32400a6ba61d4 has a passing source CI run. The current difference is documentation only. A passing export dispatch does not qualify rendered parity. Current complete-render enforcement remains an open verification requirement. [Exact-source responses and workflows](/Users/alex/.codex/automations/noisemaker-port-completion-audit/review-20260925-053200/noisemaker-for-perl-remote-evidence.json).

Environment: macOS 26.5, arm64, Perl 5.34.1, Node 26.10.0. FFmpeg encoded the animation probe.
[Tracked SHA-256 inventory](/Users/alex/.codex/automations/noisemaker-port-completion-audit/evidence-audit-20260925-010210/source-hashes.json) binds this run to the reviewed source.
The oracle archive contains regular files. Its runtime digest passed the existing integrity check.
No authority data, tests, implementation, workflow, tolerance, or golden changed.

| Command or public path | Exit | Measured result |
|---|---|---|
| `RELEASE_TESTING=1 NOISEMAKER_CPU_DIR=<verified-oracle> prove -lv t` | 0 | 22 files, 909 assertions, no test skips. |
| `NOISEMAKER_CPU_DIR=<verified-oracle> perl scripts/parity.pl` | 0 | 167 exact RGBA8 comparisons. The harness excludes 38 iterated or typed effects. |
| `perl Makefile.PL INSTALL_BASE=<private-prefix>` and `make` | 0 | Candidate configured and built. |
| `make distcheck` | 0 | Warns that both audit reports are outside MANIFEST. README links remain available. |
| `make disttest` | 0 | Archive contents pass 909 assertions with the verified oracle. |
| `make dist`, archive extraction, configure, build, `make install` | 0 | Candidate 1.000 installs into a private prefix. |
| `Pod::Checker::podchecker` over package modules | 0 | No POD errors. |
| Installed `generate`, `apply`, stdin `run`, and Perl API | 0 | README workflows produce nonuniform PNGs. API and CLI noise bytes match. |
| Installed parameter change and external PNG input | 0 | Non-square 32×24 output works. Media output matches the CPU reference exactly. |
| Invalid `seeed=3`, then corrected input | 2, 0 | Diagnostic names the parameter. Existing output survives. Recovery renders. |
| Installed animation and `ffprobe` | 0 | Three H.264 frames at 16×16. Saved frames change over time. |
| SIGINT during a 1024×1024 render | signal 2 | The process stops. Existing destination bytes survive. |
| Served `perl run.pl` and invalid DSL recovery | 0, 255, 0 | Useful 16×12 output. Diagnostic includes line and column. Existing output survives. |
| Private installation removal | verified | The audit removed only its private prefix. User outputs remain. |

[Test commands and exits](/Users/alex/.codex/automations/noisemaker-port-completion-audit/evidence-audit-20260925-010210/tests.json). [Full test log](/Users/alex/.codex/automations/noisemaker-port-completion-audit/evidence-audit-20260925-010210/source-tests.log). [Rendered sweep](/Users/alex/.codex/automations/noisemaker-port-completion-audit/evidence-audit-20260925-010210/full-parity.log).
[Distribution checks](/Users/alex/.codex/automations/noisemaker-port-completion-audit/evidence-audit-20260925-010210/distribution-tests.json). [Archive installation](/Users/alex/.codex/automations/noisemaker-port-completion-audit/evidence-audit-20260925-010210/install.json). [POD checks](/Users/alex/.codex/automations/noisemaker-port-completion-audit/evidence-audit-20260925-010210/pod.json).
[Installed workflows](/Users/alex/.codex/automations/noisemaker-port-completion-audit/evidence-audit-20260925-010210/usability.json). [Decoded output checks](/Users/alex/.codex/automations/noisemaker-port-completion-audit/evidence-audit-20260925-010210/workflow-output-checks.json).
[External-input comparison](/Users/alex/.codex/automations/noisemaker-port-completion-audit/evidence-audit-20260925-010210/media-comparison.json). [Served recovery](/Users/alex/.codex/automations/noisemaker-port-completion-audit/evidence-audit-20260925-010210/served-recovery.json). [Removal](/Users/alex/.codex/automations/noisemaker-port-completion-audit/evidence-audit-20260925-010210/removal.json).

Four independent 16×12 comparisons use seed 7 and time 0.7.
Noise with type 10 and ridges, curl, and a two-iteration Navier-Stokes case match exactly.
Four-component solid color fails. Maximum channel difference is 179 across 192 alpha channels.
Three 2×2 DSL follow-ups reproduce two failures. The three-component control matches exactly.
[Independent probes](/Users/alex/.codex/automations/noisemaker-port-completion-audit/evidence-audit-20260925-010210/independent-differential.json). [Controlled alpha reproduction](/Users/alex/.codex/automations/noisemaker-port-completion-audit/evidence-audit-20260925-010210/alpha-reproduction.json).

The existing `t/05-parity.t` runs 12 assertions. Its Navier-Stokes assertion permits a maximum channel difference of two.
That tolerance remains unchanged. A tolerant assertion does not establish exact equality.
The independent Navier-Stokes probe separately measured exact equality for its stated inputs.

Current inventories contain 210 upstream IDs and 205 port IDs.
The default sweep executes 167 cases and excludes 38. Five upstream IDs are absent.
[Case identifiers and parameter limits](COMPATIBILITY.md#3-parity-coverage). [Inventory](/Users/alex/.codex/automations/noisemaker-port-completion-audit/evidence-audit-20260925-010210/coverage-inventory.json).
The parameter comparison found missing landscape `filtering` and different remap metadata representation.
The remap representation difference needs contract reconciliation. It is not automatically an implementation defect.
[Parameter comparison](/Users/alex/.codex/automations/noisemaker-port-completion-audit/evidence-audit-20260925-010210/parameter-inventory-diff.json). [Landscape rejection](/Users/alex/.codex/automations/noisemaker-port-completion-audit/evidence-audit-20260925-010210/landscape-parameter.json).

[Exact-source CI](https://github.com/noisefactorllc/noisemaker-for-perl/actions/runs/36077699976) passed all five jobs.
Linux Perl 5.22/5.42 and macOS Perl 5.42 each pass 897 source and packaged assertions.
Those matrix jobs skip the external oracle file. The separate oracle job passes 12 assertions and 167 comparisons, with 38 exclusions.
[Downstream release](https://github.com/noisefactorllc/scaffold/actions/runs/36078402043) includes an executed Perl PNG check.
[Source CI log](/Users/alex/.codex/automations/noisemaker-port-completion-audit/evidence-audit-20260925-010210/ci-log.txt). [Release log](/Users/alex/.codex/automations/noisemaker-port-completion-audit/evidence-audit-20260925-010210/downstream-log.txt).

Official references: [ExtUtils::MakeMaker 7.78](https://perldoc.perl.org/ExtUtils::MakeMaker) and [Perl maintenance policy](https://perldoc.perl.org/perlpolicy), accessed 2026-09-25.
The current documentation lists Perl 5.44.0. This audit does not qualify that version.
The private installation uses the documented `INSTALL_BASE` mechanism.
[CPAN discovery](https://fastapi.metacpan.org/v1/release/Math-Fractal-Noisemaker) still returns historical 0.105. No GitHub release exists.
Candidate 1.000 installation and served kit 0.1.13 are separate distribution results.
Migration from 0.105 remains untested. The README explicitly declares the breaking API change.

The port provides useful offline generation and filtering in a normal Perl process.
Measured discovery, installation, outputs, diagnostics, and recovery support that bounded contribution.
A GUI accessibility check does not apply to this headless package. The audit exercised terminal help and diagnostics.
Other platforms, upgrade safety, sustained resource use, and complete current parity remain unverified.

Probe limitations: initial `/latest/` shader requests failed. The documented `/1/` path succeeded.
The kit builder rejected an archive without a Git index. Its unchanged retry used the verified checkout and reproduced every file.
[Rejected setup](/Users/alex/.codex/automations/noisemaker-port-completion-audit/evidence-audit-20260925-010210/kit-rebuild.json). [Successful reproduction](/Users/alex/.codex/automations/noisemaker-port-completion-audit/evidence-audit-20260925-010210/kit-rebuild-verified.json).

## 5. Open compatibility limits

Next bounded check: Run the three retained solid DSL cases through the installed Perl distribution and the immutable CPU reference. Require all RGBA bytes to agree without changing the existing RGB case. Then check the missing landscape filtering parameter, all 38 excluded effects, and the five missing effect IDs before rerunning the full declared gate.
See the stable entries in [completion gaps](COMPLETION_GAPS.md).

See [the gap register](COMPLETION_GAPS.md#4-known-gaps) for stable IDs, evidence, dependencies, and acceptance criteria.

1. Reproduce the alpha and landscape parameter failures for GAP-004 and GAP-005.
2. Reconcile parameter representations and define complete cases for GAP-001.
3. Add missing source-update parity enforcement through existing CI in the separate implementation job.
4. Qualify migration, current Perl, remaining hosts, and sustained resources for GAP-002.
5. Qualify the intended distribution channel and release contract for GAP-003.

Every eligible port has equal priority. None of these report changes closes an implementation gap.

## 6. History

2026-09-25 daily review at `5cf1b4e462f2865ff85fa043af0e005a3a8b7ee6`: source freshness and bounded evidence reviewed. Open qualification limits retained. [Retained review evidence](/Users/alex/.codex/automations/noisemaker-port-completion-audit/review-20260925-053200/perl-alpha-current.json). No new closure claimed.

| Date | Source | Result | Change |
|---|---|---|---|
| 2026-09-24 | `06879ebfca5c321b253af507190f85f68e0abe84` | Full qualification unverified | Created the requested maintained compatibility report. Preserved historical evidence and open gaps. |

Publication follow-up: recorded exact-source CI and retained every observed skip. No gap was closed.

Run: `20260924-remaining-gap-documents`. Later audits and reviews update this report with source-bound results.

### 2026-09-25 audit

Source: `bf02783236fdfa3d5cfb9dce64e32400a6ba61d4`. CPU authority: `749aa116730d2b294f940390a842d5d8ab5824d7`.
The existing sweep passes 167 exact cases and excludes 38. Five current upstream effect IDs remain absent.
Installed workflows and all 324 served files pass bounded checks. Nondefault alpha fails. Perl rejects landscape filtering.
No gap closes. Full parity and release readiness remain unqualified.
Earlier results remain in [the preserved report](/Users/alex/.codex/automations/noisemaker-port-completion-audit/evidence-audit-20260925-010210/before-COMPATIBILITY.md) and the preceding publication.
[Publication and queue result](/Users/alex/.codex/automations/noisemaker-port-completion-audit/evidence-audit-20260925-010210/result.json).
