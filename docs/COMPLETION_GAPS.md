# noisemaker-for-perl: completion gaps

Current compatibility matrix: [compatibility report](COMPATIBILITY.md).

## 1. Scope and source revisions

Daily review: 2026-09-25. Current inspected source: [`5cf1b4e462f2865ff85fa043af0e005a3a8b7ee6`](https://github.com/noisefactorllc/noisemaker-for-perl/commit/5cf1b4e462f2865ff85fa043af0e005a3a8b7ee6).
Full rendered parity remains **unverified** (the current bounded gate also has failures). No release approval or new closure follows from this review.
Current upstream discovery: `bbdeb56c4b75cf33379766c3e87b0f5a18bcbba8`. Published Noisemaker authority: `1.0.179`, source `fca611fd8f91424661d4e531d39313d24ea21134`, 210 effect IDs.
The observations below retain their original source and authority identities. They do not qualify later updates.
Current served kit: `0.1.13`, source `bf02783236fdfa3d5cfb9dce64e32400a6ba61d4`. Retrieved inventory and hashes (audit evidence `review-20260925-053200/current-served-inventories.json`). Artifact identity does not establish host qualification.

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
Authority delta (audit evidence `evidence-audit-20260925-010210/upstream-delta.json`). [Oracle lock](https://github.com/noisefactorllc/noisemaker-for-perl/blob/bf02783236fdfa3d5cfb9dce64e32400a6ba61d4/scripts/oracle-lock.json).

Served kit `0.1.13` identifies the reviewed source. All 324 files match their hashes and a local reproduction.
All 319 served engine files match this source. Both MIT notices are present.
[Immutable metadata](https://kits.noisedeck.app/perl/0.1.13/deployment-meta.json). Artifact verification (audit evidence `evidence-audit-20260925-010210/artifact-verification.json`).

## 2. Completion claims

| Claim ID | Claim source | Claimed scope | Finding | Evidence |
|---|---|---|---|---|
| CLAIM-001 | [README](https://github.com/noisefactorllc/noisemaker-for-perl/blob/bf02783236fdfa3d5cfb9dce64e32400a6ba61d4/README.md#parity) | 167 exact default image comparisons, with 38 exclusions | supported | The existing sweep passes. Broader parity remains open: GAP-001. |
| CLAIM-002 | [README](https://github.com/noisefactorllc/noisemaker-for-perl/blob/bf02783236fdfa3d5cfb9dce64e32400a6ba61d4/README.md#use) | Human usability through installed public entry points | partial | Installed workflows pass. Wider lifecycle checks remain open: GAP-002. |
| CLAIM-003 | [Makefile.PL](https://github.com/noisefactorllc/noisemaker-for-perl/blob/bf02783236fdfa3d5cfb9dce64e32400a6ba61d4/Makefile.PL) | Ecosystem fit and supported versions | partial | Standard packaging and POD checks pass. Minimum-version CI passes. Current Perl 5.44 and other platforms remain unverified. |
| CLAIM-004 | [Distribution instructions](https://github.com/noisefactorllc/noisemaker-for-perl/blob/bf02783236fdfa3d5cfb9dce64e32400a6ba61d4/README.md#install) | Release readiness | unverified | Candidate installation and served artifact reproduction pass. CPAN 1.000, migration, and full parity remain unqualified. |
| CLAIM-005 | [Exact-source CI](https://github.com/noisefactorllc/noisemaker-for-perl/actions/runs/36077699976) | Existing workflow and release gates | supported | Source jobs and downstream Perl render pass. The gate retains 38 exclusions. |
| CLAIM-006 | [Runtime](https://github.com/noisefactorllc/noisemaker-for-perl/blob/bf02783236fdfa3d5cfb9dce64e32400a6ba61d4/lib/Math/Fractal/Noisemaker/Renderer.pm) | Accepted color values follow the reference | contradicted | Four-component color changes solid alpha. GAP-004. |
| CLAIM-007 | [Current CPU snapshot](https://github.com/noisefactorllc/noisemaker-for-cpu/blob/749aa116730d2b294f940390a842d5d8ab5824d7/src/effects/generated/upstream-snapshot.js) | Current landscape parameter contract | contradicted | Perl rejects `filtering`. GAP-005. |

## 3. Methods and evidence

Review CI boundary: No workflow run exists at the inspected source SHA. The preceding runtime source bf02783236fdfa3d5cfb9dce64e32400a6ba61d4 has a passing source CI run. The current difference is documentation only. A passing export dispatch does not qualify rendered parity. Current complete-render enforcement remains an open verification requirement. Exact-source responses and workflows (audit evidence `review-20260925-053200/noisemaker-for-perl-remote-evidence.json`).

### Daily review, 2026-09-25

The four-component solid color defect reproduces at the current source. With color alpha 0.3 and explicit alpha 0.8, the output alpha is 61 instead of the retained reference value 204. Omitting explicit alpha produces 76 instead of 255. The original 167 exact default cases, 38 exclusions, and five missing effect IDs do not qualify full parity. Raw evidence (audit evidence `review-20260925-053200/perl-alpha-current.json`).
The review checked source changes, worker evidence, source-bound CI where present, and current served inventories. Full installed-host and platform qualification remains incomplete.

Environment: macOS 26.5, arm64, Perl 5.34.1, Node 26.10.0. FFmpeg encoded the animation probe.
Tracked SHA-256 inventory (audit evidence `evidence-audit-20260925-010210/source-hashes.json`) binds this run to the reviewed source.
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

Test commands and exits (audit evidence `evidence-audit-20260925-010210/tests.json`). Full test log (audit evidence `evidence-audit-20260925-010210/source-tests.log`). Rendered sweep (audit evidence `evidence-audit-20260925-010210/full-parity.log`).
Distribution checks (audit evidence `evidence-audit-20260925-010210/distribution-tests.json`). Archive installation (audit evidence `evidence-audit-20260925-010210/install.json`). POD checks (audit evidence `evidence-audit-20260925-010210/pod.json`).
Installed workflows (audit evidence `evidence-audit-20260925-010210/usability.json`). Decoded output checks (audit evidence `evidence-audit-20260925-010210/workflow-output-checks.json`).
External-input comparison (audit evidence `evidence-audit-20260925-010210/media-comparison.json`). Served recovery (audit evidence `evidence-audit-20260925-010210/served-recovery.json`). Removal (audit evidence `evidence-audit-20260925-010210/removal.json`).

Four independent 16×12 comparisons use seed 7 and time 0.7.
Noise with type 10 and ridges, curl, and a two-iteration Navier-Stokes case match exactly.
Four-component solid color fails. Maximum channel difference is 179 across 192 alpha channels.
Three 2×2 DSL follow-ups reproduce two failures. The three-component control matches exactly.
Independent probes (audit evidence `evidence-audit-20260925-010210/independent-differential.json`). Controlled alpha reproduction (audit evidence `evidence-audit-20260925-010210/alpha-reproduction.json`).

The existing `t/05-parity.t` runs 12 assertions. Its Navier-Stokes assertion permits a maximum channel difference of two.
That tolerance remains unchanged. A tolerant assertion does not establish exact equality.
The independent Navier-Stokes probe separately measured exact equality for its stated inputs.

Current inventories contain 210 upstream IDs and 205 port IDs.
The default sweep executes 167 cases and excludes 38. Five upstream IDs are absent.
[Case identifiers and parameter limits](COMPATIBILITY.md#3-parity-coverage). Inventory (audit evidence `evidence-audit-20260925-010210/coverage-inventory.json`).
The parameter comparison found missing landscape `filtering` and different remap metadata representation.
The remap representation difference needs contract reconciliation. It is not automatically an implementation defect.
Parameter comparison (audit evidence `evidence-audit-20260925-010210/parameter-inventory-diff.json`). Landscape rejection (audit evidence `evidence-audit-20260925-010210/landscape-parameter.json`).

[Exact-source CI](https://github.com/noisefactorllc/noisemaker-for-perl/actions/runs/36077699976) passed all five jobs.
Linux Perl 5.22/5.42 and macOS Perl 5.42 each pass 897 source and packaged assertions.
Those matrix jobs skip the external oracle file. The separate oracle job passes 12 assertions and 167 comparisons, with 38 exclusions.
[Downstream release](https://github.com/noisefactorllc/scaffold/actions/runs/36078402043) includes an executed Perl PNG check.
Source CI log (audit evidence `evidence-audit-20260925-010210/ci-log.txt`). Release log (audit evidence `evidence-audit-20260925-010210/downstream-log.txt`).

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
Rejected setup (audit evidence `evidence-audit-20260925-010210/kit-rebuild.json`). Successful reproduction (audit evidence `evidence-audit-20260925-010210/kit-rebuild-verified.json`).

### Installed-artifact qualification, 2026-09-26

Environment: Linux (Debian 12, x86_64, kernel 6.8.0), system Perl 5.36.0, Node 26.5.1. No FFmpeg in the container, so `animate` used `--save-frames`. Perl 5.22.4 and Perl 5.44.0 were built from the CPAN 5.0 source tarballs (5.22.4 needed `-Accflags='-fno-plt -fcommon -O1 -fno-strict-aliasing'`; the first plain build failed with a miniperl segfault under gcc 12.2.0/glibc 2.36; the 5.44.0 tarball matched its MetaCPAN SHA-256 `3b855066b92491cb40e86affb1ca57d1a388aa43e51b91c7806a32c2f65f96c3`). All consumers used isolated private `INSTALL_BASE` prefixes and an isolated `HOME` with `PERL5LIB` unset; user outputs lived outside every prefix. Host kernel 6.8.0 and gcc 12.2.0 facts were taken from the live container.

Defect found and fixed: the installed `bin/make-noise` added only `$FindBin::Bin/../lib` to `@INC`. On an `INSTALL_BASE` install modules live in `<prefix>/lib/perl5`, so every installed command failed with `Can't locate Math/Fractal/Noisemaker.pm in @INC` (exit 2) unless the consumer set `PERL5LIB`. The fix adds `use lib "$FindBin::Bin/../lib/perl5"`, and `t/07-cli.t` gained a regression case that stages `<prefix>/bin/make-noise` plus `lib/` under `<prefix>/lib/perl5/` and requires `--version` to succeed with no `PERL5LIB` (it fails on the unfixed script). All rows below ran the fixed installed script. The defect is inherent to the `INSTALL_BASE` layout and therefore predates this fix; how the earlier macOS CLI rows passed is not recorded in the retained macOS evidence.

| Command (installed artifact, isolated prefix) | Exit | Measured result |
|---|---|---|
| `perl Makefile.PL INSTALL_BASE=<prefix>`; `make`; `make install` | 0, 0, 0 | Candidate 1.000 installs on Perl 5.36.0, Perl 5.22.4, and Perl 5.44.0. |
| `make-noise --version` | 0 | `make-noise (Math::Fractal::Noisemaker) 1.000`. |
| `generate synth/noise --width 32 --height 32 --seed 3` twice | 0, 0 | Repeat renders byte-identical: SHA-256 `074dcadc4666c1a9bd87fa649e13e21dd2ab94b3e5651e6de7c24e6a218a3a10`. |
| `apply filter/crt <input> --seed 3`; stdin DSL `run` | 0, 0 | Same-seed `filter/crt` and DSL outputs from Perl 5.22.4 and 5.44.0 byte-match the Perl 5.36.0 outputs. (Without an explicit seed `apply` randomizes the seed, so default-seed outputs differ across runs by design.) |
| `animate synth/curl --frame-count 3 --save-frames DIR` | 0 | 3 PNG frames written; explicit message that FFmpeg is absent and no video was produced. |
| `--param seeed=3` on an existing destination | 2 | Names the parameter and accepted names; pre-existing destination bytes unchanged (verified by `cmp`). |
| Corrected `generate` after the error; unknown effect; `--width 0` | 0, 2, 2 | Recovery renders; `Unknown effect: bogus/effect`; `--width must be a positive integer`. |
| SIGINT (signal 2) to a 1024×1024 `synth/curl` render | signal 2 | An initial SIGINT aimed at the wrapping shell left the render running; a second SIGINT to the perl process, delivered after the 30-second progress report and before the 35-second one, stopped it immediately (the log ends at the 30-second line). No partial destination was written; pre-existing destination bytes survived (`cmp`). |
| 0.105 → 1.000 upgrade: install CPAN 0.105 (SHA-256 `17dfc7bded95551f6ec8ce182ab2fe197e622c3f7f5e3ee00f31f8f5b4f55e7a`, verified against MetaCPAN) into a prefix, then install 1.000 into the same prefix | 0 | All five 0.105 files (module, `make-noise`, man page, `.packlist`, `perllocal.pod`) replaced or refreshed; no 0.105-only files left; installed module reports 1.000; `Math::Fractal::Noisemaker::make()` absent; `make-noise -type noise` exits `Unknown command: '-type'` — the documented 0.105 break. Consumer files created before the upgrade kept their pre-upgrade MD5s. 0.105's own CLI could not run here: it requires noncore `Imager`/`Tie::CArray`, and the container has no root to install them. |
| 10× `generate synth/curl --width 128 --height 128 --seed 3` | 0 ×10 | Per-render 52.45–55.49 s; sampled peak RSS per process 31,400–33,040 kB, no growth trend; final SHA-256 `a702df014293c9c39bad9c17c76a7e81313467e74eeb9b28a92efae02aa2b3ba`, equal to an earlier same-input render. |
| `ExtUtils::Install::uninstall` of the `.packlist` (dry run, then real) | 0 | Every installed file removed; only `perllocal.pod` bookkeeping remained in the prefix; user outputs outside the prefix untouched. |
| `RELEASE_TESTING=0 prove -lr t` on Perl 5.36.0, 5.22.4, and 5.44.0 | 0, 0, 0 | 22 files, 900 assertions each, all pass with the `bin/make-noise` fix and the new installed-layout regression case. |

Measurement note: the 10-iteration resource run sampled each render process's cumulative `/proc/<pid>/status` VmHWM at 50 ms intervals. An earlier 20-iteration attempt was discarded after three iterations because the prefix was concurrently uninstalled (iterations 4–20 exited 127); the recorded run is a clean restart against the upgraded prefix.

Remaining limits: macOS installed upgrade and sustained-resource qualification are not automatable in this Linux-only harness; Linux Perl 5.42 installed workflows were not run locally, but the floor (5.22.4) and the current release (5.44.0) are qualified above and CI covers 5.42 source and packaged assertions; FFmpeg MP4 encoding was unavailable, so `animate` was qualified through saved PNG frames only.


2026-09-27 macOS follow-up at [`72fd6845`](https://github.com/noisefactorllc/noisemaker-for-perl/commit/72fd6845c5e8f148995c8e9abc9521c03e38d18d): macOS 26.5 arm64, Perl 5.34.1. The same isolated 0.105→1.000 upgrade, installed generate/apply/DSL/animation, invalid-input recovery, SIGINT preservation, and removal checks pass; default installation replaces all old package files, installs nine man pages, and removes all 328 package-listed files while preserving consumer files. Ten installed `synth/curl` renders at 128×128, seed 3, exit 0 in 57.4–65.3 s each; `/usr/bin/time -l` peak RSS is 34,783,232–35,078,144 bytes. Every PNG hashes to `b5a4f37617042c045c19369b99b63f04ba64c3d031152f9988c0e3f9c7c73ed6`. Tests: 912 assertions pass against pinned oracle `aaa6df50`. These are separate CLI processes, not an in-process leak test; historical 0.105 rendering remains untested. [Raw resource and workflow measurements](/tmp/worker-elves-perl-macos/result.json), [default installation](/tmp/worker-elves-perl-macos/default-install.log), [tests](/tmp/worker-elves-perl-macos/tests-pinned.log).

## 4. Known gaps

P1 means false completion or a major correctness gap. P2 means bounded correctness, coverage, or integration gaps. P3 means documentation inconsistency.
No existing gap closes in this pass.

### GAP-001: complete parity and source-update enforcement

- Status: open. Priority: P2. Category: verification.
- Affected scope: scripts/parity.pl, t/05-parity.t, oracle-lock.json, and existing CI.
- Expected behavior: Every applicable case compares with immutable current authority inputs before release.
- Observed behavior: The 167-case sweep passes. It excludes 38 cases and omits five current effect IDs. Parameter and platform coverage remain incomplete.
- Evidence: Case inventory (audit evidence `evidence-audit-20260925-010210/coverage-inventory.json`) and section 3.
- Next action: Specify rendered cases for each exclusion and missing ID. Add current-source enforcement through existing CI in the implementation job.
- Dependencies: Preserve authority provenance, goldens, and numerical contracts. Reconcile the remap metadata representation.
- Acceptance criteria: All applicable cases execute without skips or missing fixtures. Report exact and tolerance-based results separately.
- Required checks: Existing full parity suite, compiler checks, parameter cases, external inputs, chains, and stateful frames.
- Last verification: 2026-09-25.

### GAP-002: remaining installed workflow qualification

- Status: closed. Priority: P2. Category: usability.
- Affected scope: README.md, public API, CLI, supported hosts, and lifecycle.
- Expected behavior: Developers can install, render, recover, cancel, upgrade, and remove the package on supported hosts.
- Observed behavior: Private installation, README workflows, diagnostics, cancellation, and removal pass on macOS Perl 5.34.1. On Linux, an installed-CLI defect was found and fixed: `bin/make-noise` only searched `<prefix>/lib`, so an `INSTALL_BASE` install failed with "Can't locate Math/Fractal/Noisemaker.pm" unless `PERL5LIB` was set. With the fix, install, README workflows, errors, recovery, cancellation, 0.105→1.000 upgrade over an occupied prefix, 10-iteration sustained rendering (peak RSS 31.4–33.0 MB, stable), and packlist removal pass on Linux Perl 5.22.4 (minimum), 5.36.0, and 5.44.0 (current) with byte-identical outputs and 900 passing assertions per version. The macOS 5.34.1 follow-up above passes upgrade, repeated rendering, bounded resource measurements, and removal.
- Evidence: Installed evidence (audit evidence `evidence-audit-20260925-010210/usability.json`), section 3 ("Installed-artifact qualification, 2026-09-26"), and section 6.
- Next action: None for the measured Linux/macOS installed workflows.
- Dependencies: Use isolated consumers. Preserve user files and the documented 0.105 compatibility boundary.
- Acceptance criteria: Retain commands, output bytes, resource measurements, and recovery results for each supported environment.
- Required checks: Minimum and current Perl versions, platform matrix, errors, cancellation, upgrade, and removal.
- Last verification: 2026-09-27.

### GAP-003: distribution and release qualification

- Status: open. Priority: P2. Category: release.
- Affected scope: Makefile.PL, MANIFEST, package metadata, notices, and publication evidence.
- Expected behavior: The identified distribution installs and produces useful output with explicit compatibility limits.
- Observed behavior: Candidate 1.000 and kit 0.1.13 pass bounded checks. CPAN still serves 0.105. Migration and complete parity remain unqualified.
- Evidence: Artifact evidence (audit evidence `evidence-audit-20260925-010210/artifact-verification.json`) and section 3.
- Next action: Qualify the intended package channel and migration path. Retain source-bound artifact, license, installation, and render evidence.
- Dependencies: Complete GAP-001 and the remaining GAP-002 acceptance checks. Keep module and kit versions distinct.
- Acceptance criteria: Every declared release channel identifies tested bytes. Installed examples, migration, notices, and platform requirements pass.
- Required checks: Existing package tests, exact-source CI, served hashes, installed examples, upgrades, and removal.
- Last verification: 2026-09-25.

### GAP-004: four-component color changes solid alpha

- Status: open. Priority: P2. Category: implementation.
- Affected scope: Renderer.pm color coercion and the generated synth/solid kernel binding.
- Expected behavior: A vec3 color uniform must not consume the separate alpha parameter. Accepted input must follow the reference.
- Observed behavior: At alpha 1, color [0.2,0.4,0.6,0.3] yields alpha 76 instead of 255. At alpha 0.8, it yields 61 instead of 204.
- Evidence: Reproduction (audit evidence `evidence-audit-20260925-010210/alpha-reproduction.json`) and section 3.
- Next action: In the implementation job, trace color normalization into vec3 bindings. Add a regression for three-component and four-component inputs.
- Dependencies: Retain the current GLSL, CPU reference, and accepted-input contract. Do not change authority bytes to match the port.
- Acceptance criteria: Both APIs and DSL produce the reference RGBA8 bytes for the retained probes. The existing suite still passes.
- Required checks: The 2×2 DSL probes, 16×12 API probe, full existing parity suite, and installed-artifact checks.
- Last verification: 2026-09-25.

### GAP-005: landscape filtering parameter absent

- Status: open. Priority: P2. Category: implementation.
- Affected scope: Bundled metadata, Renderer.pm validation, and renderLandscape3d bindings.
- Expected behavior: The port must accept and apply current landscape filtering choices or document the unsupported contract.
- Observed behavior: The current CPU definition contains filtering. Perl rejects filtering=1 before rendering.
- Evidence: Public rejection (audit evidence `evidence-audit-20260925-010210/landscape-parameter.json`) and section 3.
- Next action: In the implementation job, reconcile landscape metadata and bindings against the immutable authority. Test each filtering choice with nonuniform volume inputs.
- Dependencies: Identify current parameter semantics and source provenance before changing generated data.
- Acceptance criteria: Supported choices compile and produce source-bound native comparisons. Unsupported choices remain explicit qualification failures.
- Required checks: Public parameter validation, landscape DSL rendering, nondefault inputs, and the existing regression suite.
- Last verification: 2026-09-25.

## 5. Ordered next actions

Current first action: Run the three retained solid DSL cases through the installed Perl distribution and the immutable CPU reference. Require all RGBA bytes to agree without changing the existing RGB case. Then check the missing landscape filtering parameter, all 38 excluded effects, and the five missing effect IDs before rerunning the full declared gate.
Subsequent historical actions remain dependent on that evidence. No implementation is authorized by this audit.

1. Reproduce GAP-004 and GAP-005 with the retained public inputs before any implementation change.
2. Resolve the parameter contracts and add regression checks in the separate implementation job.
3. Define the missing rendered cases for GAP-001, then enforce them through existing CI.
4. Complete installed migration and host qualification for GAP-002.
5. Qualify the intended package channel and release criteria for GAP-003.

This audit authorizes no implementation work, new effects, or parity checkpoint advancement.

## 6. Pass history

2026-09-26 GAP-002 implementation at this commit: fixed the installed-CLI `INSTALL_BASE` `@INC` defect in `bin/make-noise` with an installed-layout regression case in `t/07-cli.t`, and recorded installed-artifact qualification on Linux Perl 5.22.4 (minimum), 5.36.0, and 5.44.0 (current) — workflows, errors, recovery, cancellation, 0.105→1.000 upgrade, sustained 10-iteration resource run, removal — in section 3. GAP-002 moves to blocked: macOS upgrade and sustained-resource qualification need macOS hardware this harness lacks. No parity, authority, or tolerance change.

2026-09-25 daily review at `5cf1b4e462f2865ff85fa043af0e005a3a8b7ee6`: source freshness and bounded evidence reviewed. Open qualification limits retained. Retained review evidence (audit evidence `review-20260925-053200/perl-alpha-current.json`). No new closure claimed.

| Date | Source SHA | Changes | Tested scope | Remaining limits |
|---|---|---|---|---|
| 2026-09-24 | `06879ebfca5c321b253af507190f85f68e0abe84` | Created six-section register and README link. No closures. | Four selected files passed: 120 assertions. CLI, output runtime, distribution inventory, and parameter checks ran. Full parity did not run. | Full audit, installed workflows, current rendered parity, platforms, and releases remain unqualified. |

Run ID: `20260924-remaining-gap-documents`.
Operational evidence (audit evidence `evidence-20260924-remaining-gap-documents`). Creating this register does not advance successful-audit timestamps or the rotation.

### 2026-09-25 audit

Source: `bf02783236fdfa3d5cfb9dce64e32400a6ba61d4`. Run: `audit-20260925-010210`.
Executed 909 assertions, the 167-case exact sweep, archive installation, useful workflows, and served-artifact checks.
Retained all 38 sweep exclusions and five absent upstream IDs. Added GAP-004 and GAP-005. No gap closed.
The original register remains in the preceding publication and the preserved snapshot (audit evidence `evidence-audit-20260925-010210/before-COMPLETION_GAPS.md`).
Publication verification and queue state reside in the run result (audit evidence `evidence-audit-20260925-010210/result.json`).
