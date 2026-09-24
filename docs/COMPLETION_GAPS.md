# noisemaker-for-perl: completion gaps

Current compatibility matrix: [compatibility report](COMPATIBILITY.md).

## 1. Scope and source revisions

Date: 2026-09-24. Reviewed SHA: [`06879ebfca5c321b253af507190f85f68e0abe84`](https://github.com/noisefactorllc/noisemaker-for-perl/commit/06879ebfca5c321b253af507190f85f68e0abe84).
Local HEAD matched remote main before checks. The operator requested registers for all remaining eligible ports in this run.
This initial register contains bounded evidence. It is not a completed port audit or release approval.
No implementation or parity checkpoint changed. Full audits remain in the rotation.

Offline Perl CPU rendering for a 205-effect catalog. Perl 5.22 is the documented floor. FFmpeg is optional for saved PNG frames. [Contract](https://github.com/noisefactorllc/noisemaker-for-perl/blob/06879ebfca5c321b253af507190f85f68e0abe84/README.md).

`scripts/oracle-lock.json` pins CPU revision `16c38245c42030c8ee46dc61108791d2fea4bda9` and upstream revision `44bc4ed4ac729bddaa95b083d64bee942ade35da`.
Current upstream at discovery: `c9ee8a049b2b63cd300da67c01ee40baf29dc288`.
Current CPU authority: `f2eb495d70abcb74e3632e7a652a4f83e4f3b11e`.
These authority heads are review targets, not qualification results. No goldens were regenerated.

Served kit `0.1.9` identifies `06879ebfca5c321b253af507190f85f68e0abe84`. [Metadata](https://kits.noisedeck.app/perl/0/deployment-meta.json). Inventory and compatibility metadata were retrieved. Complete artifact bytes were not checked.

The README triggers source tests, pinned parity, and export-kit publication. The audit must verify downstream results before completion.
The containing commit identifies this register's publication revision. The shared run record retains commits, remote hashes, and downstream results.

## 2. Completion claims

| Claim ID | Claim source | Claimed scope | Finding | Evidence |
|---|---|---|---|---|
| CLAIM-001 | [Historical source](https://github.com/noisefactorllc/noisemaker-for-perl/blob/06879ebfca5c321b253af507190f85f68e0abe84/README.md) | 167 default image effects compare with exact RGBA8 bytes. The remaining 38 iterated and typed effects are outside that sweep. | partial | Four selected files passed: 120 assertions. CLI, output runtime, distribution inventory, and parameter checks ran. Full parity did not run. |
| CLAIM-002 | [README](https://github.com/noisefactorllc/noisemaker-for-perl/blob/06879ebfca5c321b253af507190f85f68e0abe84/README.md) | Human usability: installation, output, errors, and recovery | unverified | Complete installed workflows were not observed. GAP-002. |
| CLAIM-003 | [Ecosystem reference](https://perldoc.perl.org/ExtUtils::MakeMaker) | Ecosystem fit and version support | partial | Source entry points were examined. Installed integration and version qualification remain open. |
| CLAIM-004 | [README](https://github.com/noisefactorllc/noisemaker-for-perl/blob/06879ebfca5c321b253af507190f85f68e0abe84/README.md) | Release readiness | unverified | Metadata and CI do not replace installation of the actual artifact. GAP-003. |
| CLAIM-005 | [Exact-source Actions](https://github.com/noisefactorllc/noisemaker-for-perl/actions?query=head_sha%3A06879ebfca5c321b253af507190f85f68e0abe84) | Workflow status only | supported | [Export kit](https://github.com/noisefactorllc/noisemaker-for-perl/actions/runs/35822900063): `success`. |

## 3. Methods and evidence

Environment: macOS 26.5, Darwin arm64.
[Source SHA-256 records](/Users/alex/.codex/automations/noisemaker-port-completion-audit/evidence-20260924-remaining-gap-documents/noisemaker-for-perl-source-hashes.json) bind these checks to the reviewed revision.
[Raw command evidence](/Users/alex/.codex/automations/noisemaker-port-completion-audit/evidence-20260924-remaining-gap-documents/perl-tests.json). [Remote evidence](/Users/alex/.codex/automations/noisemaker-port-completion-audit/evidence-20260924-remaining-gap-documents/noisemaker-for-perl-remote.json).

Executed command:

```sh
prove -l t/07-cli.t t/16-output-runtime.t t/19-distribution.t t/21-parameters.t
```

Four selected files passed: 120 assertions. CLI, output runtime, distribution inventory, and parameter checks ran. Full parity did not run. Final exit code: 0.
No image denominator or tolerance follows from a unit-test or generated-file result.
Official reference: [Current ExtUtils::MakeMaker documentation, accessed 2026-09-24](https://perldoc.perl.org/ExtUtils::MakeMaker).

| Outcome | Observed scope | Remaining work |
|---|---|---|
| Installation | Instructions and metadata inspected | Install the actual artifact privately. |
| First useful output | Selected checks only | Install with a private prefix. Render generate and apply examples, run DSL from stdin, preserve destinations on errors, then remove the package. |
| Host integration | Not fully exercised | Check parameters, external inputs, state, resize, and cleanup. |
| Errors and recovery | Only the selected checks above | Fail through the installed entry point, correct input, and render again. |
| Distribution | Metadata inspection | Run make distcheck and make disttest in an isolated copy. Install its archive privately. Check POD, notices, upgrade behavior, and removal. |
| Accessibility | Not observed | Check keyboard, focus, labels, and diagnostics for provided interfaces. |

Headless libraries do not require an editor accessibility test. Their CLI diagnostics and failure handling still require checks.
Host presence does not prove host qualification. This pass made no global installation or user-project changes.

## 4. Known gaps

P1 means false completion or major correctness failure. P2 means coverage or integration uncertainty. P3 means documentation inconsistency.
These entries record missing qualification. They do not infer implementation defects from absent tests.

### GAP-001: current authority and parity qualification

- Status: open. Priority: P2. Category: verification.
- Affected scope: README.md, Makefile.PL, MANIFEST, scripts/oracle-lock.json, scripts/parity.pl, t/
- Expected behavior: Reproducible evidence binds each supported claim to the port and authority revisions.
- Observed behavior: Exact default image parity does not qualify the 38 excluded effects or migration from API 0.105. Retain that breaking-change boundary.
- Evidence: [Historical source](https://github.com/noisefactorllc/noisemaker-for-perl/blob/06879ebfca5c321b253af507190f85f68e0abe84/README.md) and section 3.
- Next action: Run the locked 167-effect gate. Qualify the 38 exclusions separately with stateful scenes, parameters, sizes, and explicit tolerances.
- Dependencies: Resolve immutable authority inputs. Preserve historical goldens and provenance.
- Acceptance criteria: Report every applicable case, parameter choice, exclusion, error, and tolerance. Do not reduce the denominator to report success.
- Required checks: Existing compiler and rendered parity gates, with raw output and exact source hashes.
- Last verification: 2026-09-24. Full behavior qualification remains unverified.

### GAP-002: installed developer workflow qualification

- Status: open. Priority: P2. Category: usability.
- Affected scope: Public API, examples, supported hosts, errors, recovery, and lifecycle.
- Expected behavior: Developers can install, produce useful output, integrate it, recover from errors, and remove the package.
- Observed behavior: This pass did not exercise the complete installed workflow or supported-version matrix.
- Evidence: [README](https://github.com/noisefactorllc/noisemaker-for-perl/blob/06879ebfca5c321b253af507190f85f68e0abe84/README.md), [official reference](https://perldoc.perl.org/ExtUtils::MakeMaker), and section 3.
- Next action: Install with a private prefix. Render generate and apply examples, run DSL from stdin, preserve destinations on errors, then remove the package.
- Dependencies: Use an isolated consumer. Identify host, GPU, licensing, and input requirements before execution.
- Acceptance criteria: Retain artifact hashes, steps, meaningful output, error diagnostics, recovery results, and cleanup results.
- Required checks: Test minimum and current supported versions. Check cancellation and file preservation where relevant. Keep unavailable platforms explicit.
- Last verification: 2026-09-24. Source inspection does not close this gap.

### GAP-003: distribution and release qualification

- Status: open. Priority: P2. Category: release.
- Affected scope: Actual artifact, dependencies, notices, version promises, and release evidence.
- Expected behavior: The delivered artifact supports its documented installation and first useful result.
- Observed behavior: Complete artifact reproduction, installation, upgrade, and removal remain unverified.
- Evidence: [Distribution instructions](https://github.com/noisefactorllc/noisemaker-for-perl/blob/06879ebfca5c321b253af507190f85f68e0abe84/README.md), section 1, and exact-source CI in section 2.
- Next action: Run make distcheck and make disttest in an isolated copy. Install its archive privately. Check POD, notices, upgrade behavior, and removal.
- Dependencies: Complete GAP-002 for the candidate. Distinguish source CI from downstream publication and native rendering.
- Acceptance criteria: Match artifact bytes to their inventory. Check notices and dependencies. Pass installation, examples, upgrade, and removal.
- Required checks: Inspect exact-source CI jobs and actual render legs. Count skips and errors rather than trusting green summaries.
- Last verification: 2026-09-24. This register does not approve a release.

## 5. Ordered next actions

1. Resolve authority identities for GAP-001. Retain earlier denominators, goldens, tolerances, and exclusions.
2. Execute the installed workflow for GAP-002. Record meaningful output, failure recovery, versions, and cleanup.
3. Run compiler and rendered parity for GAP-001. Keep structural, numerical, and platform evidence separate.
4. Qualify distribution contents and lifecycle for GAP-003 after the installed workflow passes.
5. Record measured results. Close entries only when their acceptance criteria pass.

Implementation belongs to the separate job. Do not port additional effects or advance the current parity checkpoint through this register.

## 6. Pass history

| Date | Source SHA | Changes | Tested scope | Remaining limits |
|---|---|---|---|---|
| 2026-09-24 | `06879ebfca5c321b253af507190f85f68e0abe84` | Created six-section register and README link. No closures. | Four selected files passed: 120 assertions. CLI, output runtime, distribution inventory, and parameter checks ran. Full parity did not run. | Full audit, installed workflows, current rendered parity, platforms, and releases remain unqualified. |

Run ID: `20260924-remaining-gap-documents`.
[Operational evidence](/Users/alex/.codex/automations/noisemaker-port-completion-audit/evidence-20260924-remaining-gap-documents). Creating this register does not advance successful-audit timestamps or the rotation.
