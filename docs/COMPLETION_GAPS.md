# noisemaker-for-perl: completion gaps

Current compatibility matrix: [compatibility report](COMPATIBILITY.md).

## 1. Scope and source revisions

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

## 4. Known gaps

P1 means false completion or a major correctness gap. P2 means bounded correctness, coverage, or integration gaps. P3 means documentation inconsistency.
No existing gap closes in this pass.

### GAP-001: complete parity and source-update enforcement

- Status: open. Priority: P2. Category: verification.
- Affected scope: scripts/parity.pl, t/05-parity.t, oracle-lock.json, and existing CI.
- Expected behavior: Every applicable case compares with immutable current authority inputs before release.
- Observed behavior: The 167-case sweep passes. It excludes 38 cases and omits five current effect IDs. Parameter and platform coverage remain incomplete.
- Evidence: [Case inventory](/Users/alex/.codex/automations/noisemaker-port-completion-audit/evidence-audit-20260925-010210/coverage-inventory.json) and section 3.
- Next action: Specify rendered cases for each exclusion and missing ID. Add current-source enforcement through existing CI in the implementation job.
- Dependencies: Preserve authority provenance, goldens, and numerical contracts. Reconcile the remap metadata representation.
- Acceptance criteria: All applicable cases execute without skips or missing fixtures. Report exact and tolerance-based results separately.
- Required checks: Existing full parity suite, compiler checks, parameter cases, external inputs, chains, and stateful frames.
- Last verification: 2026-09-25.

### GAP-002: remaining installed workflow qualification

- Status: open. Priority: P2. Category: usability.
- Affected scope: README.md, public API, CLI, supported hosts, and lifecycle.
- Expected behavior: Developers can install, render, recover, cancel, upgrade, and remove the package on supported hosts.
- Observed behavior: Private installation, README workflows, diagnostics, cancellation, and removal pass on macOS Perl 5.34.1. Upgrades and sustained resource behavior remain unverified.
- Evidence: [Installed evidence](/Users/alex/.codex/automations/noisemaker-port-completion-audit/evidence-audit-20260925-010210/usability.json) and section 3.
- Next action: Measure migration, repeated renders, resource behavior, and supported host workflows with installed artifacts.
- Dependencies: Use isolated consumers. Preserve user files and the documented 0.105 compatibility boundary.
- Acceptance criteria: Retain commands, output bytes, resource measurements, and recovery results for each supported environment.
- Required checks: Minimum and current Perl versions, platform matrix, errors, cancellation, upgrade, and removal.
- Last verification: 2026-09-25.

### GAP-003: distribution and release qualification

- Status: open. Priority: P2. Category: release.
- Affected scope: Makefile.PL, MANIFEST, package metadata, notices, and publication evidence.
- Expected behavior: The identified distribution installs and produces useful output with explicit compatibility limits.
- Observed behavior: Candidate 1.000 and kit 0.1.13 pass bounded checks. CPAN still serves 0.105. Migration and complete parity remain unqualified.
- Evidence: [Artifact evidence](/Users/alex/.codex/automations/noisemaker-port-completion-audit/evidence-audit-20260925-010210/artifact-verification.json) and section 3.
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
- Evidence: [Reproduction](/Users/alex/.codex/automations/noisemaker-port-completion-audit/evidence-audit-20260925-010210/alpha-reproduction.json) and section 3.
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
- Evidence: [Public rejection](/Users/alex/.codex/automations/noisemaker-port-completion-audit/evidence-audit-20260925-010210/landscape-parameter.json) and section 3.
- Next action: In the implementation job, reconcile landscape metadata and bindings against the immutable authority. Test each filtering choice with nonuniform volume inputs.
- Dependencies: Identify current parameter semantics and source provenance before changing generated data.
- Acceptance criteria: Supported choices compile and produce source-bound native comparisons. Unsupported choices remain explicit qualification failures.
- Required checks: Public parameter validation, landscape DSL rendering, nondefault inputs, and the existing regression suite.
- Last verification: 2026-09-25.

## 5. Ordered next actions

1. Reproduce GAP-004 and GAP-005 with the retained public inputs before any implementation change.
2. Resolve the parameter contracts and add regression checks in the separate implementation job.
3. Define the missing rendered cases for GAP-001, then enforce them through existing CI.
4. Complete installed migration and host qualification for GAP-002.
5. Qualify the intended package channel and release criteria for GAP-003.

This audit authorizes no implementation work, new effects, or parity checkpoint advancement.

## 6. Pass history

| Date | Source SHA | Changes | Tested scope | Remaining limits |
|---|---|---|---|---|
| 2026-09-24 | `06879ebfca5c321b253af507190f85f68e0abe84` | Created six-section register and README link. No closures. | Four selected files passed: 120 assertions. CLI, output runtime, distribution inventory, and parameter checks ran. Full parity did not run. | Full audit, installed workflows, current rendered parity, platforms, and releases remain unqualified. |

Run ID: `20260924-remaining-gap-documents`.
[Operational evidence](/Users/alex/.codex/automations/noisemaker-port-completion-audit/evidence-20260924-remaining-gap-documents). Creating this register does not advance successful-audit timestamps or the rotation.

### 2026-09-25 audit

Source: `bf02783236fdfa3d5cfb9dce64e32400a6ba61d4`. Run: `audit-20260925-010210`.
Executed 909 assertions, the 167-case exact sweep, archive installation, useful workflows, and served-artifact checks.
Retained all 38 sweep exclusions and five absent upstream IDs. Added GAP-004 and GAP-005. No gap closed.
The original register remains in the preceding publication and [the preserved snapshot](/Users/alex/.codex/automations/noisemaker-port-completion-audit/evidence-audit-20260925-010210/before-COMPLETION_GAPS.md).
Publication verification and queue state reside in [the run result](/Users/alex/.codex/automations/noisemaker-port-completion-audit/evidence-audit-20260925-010210/result.json).
