# AASAL WEB — ANTIGRAVITY AUTHORITATIVE CONTINUATION — 2026-09-18

This file is the authoritative handoff for continuing the AASAL Web Final Exact-Head Closure after Codex credit exhaustion.

## 0. Role and operating mode

Act as the execution agent for the existing closure mission. Do **not** redesign the product and do **not** restart planning.

Source of truth:
- Private repo: `ankarawi/aasal-web`
- Branch: `source-audit-final-v3-fresh`
- Open draft PR: `#157` — QA trigger only, **never merge it unless Supervisor explicitly orders that later**
- Public helper repo: `ankarawi/windows-test-grid`

The Supervisor remains final visual approver.

Never claim PASS/DONE/FINAL from prior logs. Fresh-read the current branch and verify every runtime result yourself.

## 1. Current verified state

As of the latest supervisor fresh-read:

```text
AASAL_WEB_BRANCH=source-audit-final-v3-fresh
CURRENT_REMOTE_HEAD=c298c3edafac88aa274ddb76450db3516402de58
SOURCE_IMPLEMENTATION_PARENT=126526d42060d6d1fdce11295dcfdbe12c049969
QA_GATE_COMMIT=2a9fdb7bc2fa978b3fee13647f2c930cd7522baa
MAIN_MUTATED=NO
MERGE=NO
PRODUCTION_DEPLOYED=NO
CLOUDFLARE_MUTATED=NO
```

Commit `2a9fdb7...` is QA-only on top of the product-source commit `126526d...`.

The QA commit adds:
- `.qa/final-exact-head-closure/01.b64 ... 07.b64`
- final Exact-Head QA workflow changes
- no product source mutation

Before doing anything, run:

```powershell
git fetch origin
git status --short
git rev-parse HEAD
git rev-parse origin/source-audit-final-v3-fresh
git log -2 --oneline origin/source-audit-final-v3-fresh
```

Expected current remote head is `c298c3edafac88aa274ddb76450db3516402de58`.
If the remote moved, fresh-read and use the latest head. Do not work on a stale SHA.

## 2. What Codex completed

Codex completed the following:

1. Fresh-verified the original source closure head `126526d42060d6d1fdce11295dcfdbe12c049969`.
2. Audited the existing browser tests and proved the earlier `supervisor-visual-reconstruction` test alone was insufficient:
   - old evidence path was `20260917`
   - Gift/Campaign relied on Mock API for important paths
   - responsive Gift/Campaign coverage was insufficient
   - three theme selectors were not equal to full theme permutation QA
3. Identified and reused the existing real local backend harness:
   - `tests/helpers/m3-local-api-harness.ts`
   - actual Worker router
   - full local migrations
   - D1-compatible SQLite
4. Built an Exact-Head closure harness and stored it in seven base64 parts under:
   `.qa/final-exact-head-closure/*.b64`
5. Added QA-only commit `2a9fdb7...`, then supervisor audit found corruption in the prepared Base64 harness (missing Quran/Hifz tail + missing `drillAthkar()` + manifest typo). A QA-only repair commit `c298c3edafac88aa274ddb76450db3516402de58` fixed the harness. `01.b64` now contains the complete corrected Base64 payload and `02.b64 ... 07.b64` are intentionally empty, so the existing join/decode command remains valid.
6. Opened draft PR #157 only to trigger CI.
7. Proved GitHub Actions in the private repo is blocked **before runner assignment**:
   - run `35368038035`
   - jobs had `runner_id=0`
   - `steps=[]`
   - rerun reproduced the same condition
   This is infrastructure, not a test/source failure.
8. Investigated `windows-test-grid`.
9. Added secure helper infrastructure there at current helper commit `16695dc2df69972351915b4fb43b5ffd20cdcba0`:
   - `.github/workflows/aasal-secure-bootstrap.yml`
   - `.github/workflows/aasal-private-checkout-probe.yml`
   - `.github/workflows/aasal-secure-exact-head.yml`
   - `.secure/aasal-dh-public.json`
   - `.secure/aasal-session-v2.json`
10. Secure bootstrap succeeded.
11. Private checkout probe failed because the public repo's `GITHUB_TOKEN` cannot read the private repo:
    `fatal: repository 'https://github.com/ankarawi/aasal-web/' not found`
12. No `.secure/aasal-run-request-v2.json` exists and no `Aasal Secure Exact Head Closure` run has executed yet.

## 3. Preferred continuation path — use the local private clone

Because Antigravity runs on the Supervisor's computer and can use the user's GitHub-authenticated environment, **prefer local execution** over the public-grid bridge.

Find the existing local clone of `ankarawi/aasal-web`. If it exists, use it. If absent, clone the private repo using the user's already-authorized GitHub environment.

Do not ask the Supervisor to manually repeat repository details.

Create an isolated worktree if useful:

```powershell
git fetch origin
git worktree add ..\aasal-web-exact-head origin/source-audit-final-v3-fresh
cd ..\aasal-web-exact-head
git status --short
git rev-parse HEAD
git rev-parse origin/source-audit-final-v3-fresh
```

The worktree must be clean before testing.

## 4. Assemble the prepared closure harness

The QA harness is already encoded in:

```text
.qa/final-exact-head-closure/01.b64
.qa/final-exact-head-closure/02.b64
.qa/final-exact-head-closure/03.b64
.qa/final-exact-head-closure/04.b64
.qa/final-exact-head-closure/05.b64
.qa/final-exact-head-closure/06.b64
.qa/final-exact-head-closure/07.b64
```

On PowerShell:

```powershell
$parts = Get-ChildItem ".qa/final-exact-head-closure" -Filter "*.b64" | Sort-Object Name
if ($parts.Count -ne 7) { throw "QA_GATE_PART_COUNT=$($parts.Count)" }
$encoded = ($parts | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join ""
$bytes = [Convert]::FromBase64String($encoded)
[IO.File]::WriteAllBytes((Join-Path $PWD "tests/final-exact-head-closure.browser.test.ts"), $bytes)
Get-FileHash tests/final-exact-head-closure.browser.test.ts -Algorithm SHA256
```

The assembled file is temporary execution material. Do not commit it unless a genuine harness repair is required.

## 5. Required Exact-Head gates

Run against the fresh current branch head:

```powershell
npm ci
npm run typecheck
npm run worker:typecheck
npm run build:web
npm run test:gift-share-visual
npm run test:supervisor-visual-reconstruction

node tests/p4-adhkar-duas-pages.mjs
node tests/create-wizard-routes.mjs
node tests/create-publish-privacy-continuity.mjs
node tests/gift-publish-ownership-continuity.mjs
node tests/campaign-product-slice.mjs

node tests/quran-reader-prehydration-text-priority-contract.mjs
node tests/quran-reader-text-entry-contract.mjs
node tests/web4-quran-reader-shell-contract.mjs

npm exec -- tsx tests/web4-cross-product-browser.test.ts
```

Then run the prepared closure harness with the exact fresh remote SHA supplied through the environment:

```powershell
$remote=(git rev-parse origin/source-audit-final-v3-fresh).Trim()
$env:AASAL_REMOTE_HEAD=$remote
$env:AASAL_TYPECHECK_RESULT="PASS"
$env:AASAL_WORKER_TYPECHECK_RESULT="PASS"
$env:AASAL_BUILD_RESULT="PASS"
$env:AASAL_RELEVANT_TESTS_RESULT="PASS"
npm exec -- tsx tests/final-exact-head-closure.browser.test.ts
```

Do not mark those env results PASS unless their corresponding command really passed in this run.

## 6. Browser QA contract to prove

The final harness is intended to prove all of the following.

### Gift
Desktop ~1440, Tablet ~1024, Mobile ~390:
- select intention
- minimum fields
- live preview
- real local Worker/D1 create
- actual result id/slug
- reopen generated page
- ownership/privacy continuity
- share visual
- deterministic image fallback
- no horizontal overflow
- no fixed-bar occlusion
- no modal overflow
- primary action visible
- form fields usable
- preview usable

### Campaign
Desktop/Tablet/Mobile:
- intention/type
- action/target/name
- live preview
- real local Worker/D1 create
- initial goal/task
- participant route
- participant sees purpose/progress/action
- primary participant action
- share
- responsive invariants

### Quran textual reader
Desktop/Tablet/Mobile, actual interactions:
- Audio
- Tafsir
- Translation
- Search
- Bookmark
- Hifz
- Study
- Library
- Reader Settings

For each:
- Quran text remains visible
- reading position preserved
- return to reading works
- no panel collision
- no toolbar collision

### Comprehensive Athkar
Desktop + Mobile:
`الأذكار الشاملة → Category → Chapter → Branch → Content`

Also prove:
- search still works
- breadcrumb correct
- content not flattened
- moment rail contract preserved
- no invented content introduced by the UI/test

### Masbaha
- visible identity: `مسبحة آصال`
- primary intent: `سبّح الآن`
- counter interaction works
- mobile fit passes

### Themes
Actual UI switching/rendering, not DOM presence only.

Required critical surfaces:
- Gift creation
- Gift result
- Campaign creation
- Campaign participant
- Quran textual reader
- comprehensive Athkar
- Masbaha Aasal

Themes:
- midnight-gold
- midnight-blue
- parchment

The browser run must execute the 7 × 3 permutations and record them in the manifest. Representative screenshots are sufficient; do not create hundreds.

## 7. Durable evidence required

Create/verify:

```text
qa-docs/visual-reconstruction-20260918/
  manifest.json
  README.md
  SHA256SUMS.txt
  *.webp
```

Manifest must record at least:
- gitHead
- remoteHead
- browserExecutable
- browserVersion
- buildResult
- typecheckResult
- workerTypecheckResult
- relevantTestsResult
- Gift desktop/tablet/mobile + realLocalCreate + shareVisual + fallback
- Campaign desktop/tablet/mobile + realLocalCreate + participantFlow
- Quran nine tools + desktop/tablet/mobile
- Athkar hierarchy + desktop/mobile
- Tasbih identity/interaction/mobile
- themes midnight-gold/midnight-blue/parchment
- horizontalOverflowFailures=0
- uncaughtRuntimeExceptions=0
- unexpectedConsoleErrors=0
- essentialAssetFailures=0

Use high-quality WebP representative screenshots.

## 8. Known contract defect comparison

The historical source parent before the product implementation commit is:

`17cbb0b81d30e088421392a3b2787caf48a06200`

Run `tests/aasal-web3-product-contract.mjs` on the tested Exact Head and compare it with that base.

The previously known failure at line 263 may be recorded only as:

`PRE_EXISTING_UNRELATED_DEFECT`

if the same signature is independently demonstrated on the base. Do not repair it in this closure unless the current implementation caused a regression.

## 9. Write policy

Allowed without further confirmation:
- QA/test harness repair
- evidence generation
- docs/evidence commits
- minimal product fix only if Exact-Head QA exposes a genuine defect caused by the current implementation

Forbidden:
- redesign
- broad refactor
- merge PR #157
- mutate `main`
- production deployment
- Cloudflare production mutation
- unrelated fixes

If a real source defect is found:
1. capture exact reproduction/evidence,
2. apply the smallest source fix,
3. commit to `source-audit-final-v3-fresh`,
4. Fresh-Verify the new Remote HEAD,
5. rerun all affected gates and regenerate evidence against the new committed head.

Never reuse evidence from a pre-fix SHA.

## 10. Evidence commit

After the run passes, remove the temporary assembled test file if it is untracked/generated, then commit only durable evidence (and any necessary QA harness fix if one was genuinely required).

Before push:

```powershell
git status --short
git diff --cached --name-only
```

Push only to:

`source-audit-final-v3-fresh`

No merge.

After push, Fresh-Verify local and remote again.

## 11. Required final report

Return:

```text
FINAL_HEAD=
REMOTE_HEAD=
EXACT_HEAD_BROWSER_EVIDENCE=
EVIDENCE_PATH=
SCREENSHOT_COUNT=

GIFT_FUNNEL=
GIFT_REAL_LOCAL_CREATE=
GIFT_IMAGE_FALLBACK=

CAMPAIGN_FUNNEL=
CAMPAIGN_REAL_LOCAL_CREATE=
CAMPAIGN_PARTICIPANT_FLOW=

QURAN_TEXT_READER=
QURAN_TOOL_INTERACTIONS=

COMPREHENSIVE_ATHKAR_HIERARCHY=
MASBAHA_AASAL=

DESKTOP_BROWSER_QA=
TABLET_BROWSER_QA=
MOBILE_BROWSER_QA=
THREE_THEME_BROWSER_QA=

TYPECHECK=
WORKER_TYPECHECK=
BUILD=
RELEVANT_TESTS=

PRE_EXISTING_UNRELATED_DEFECTS=

MAIN_MUTATED=NO
PRODUCTION_DEPLOYED=NO
CLOUDFLARE_MUTATED=NO
```

Do not use:
- VISUAL_ACCEPTED
- FINAL_ACCEPTED
- PRODUCTION_READY

If every gate is proven and durable evidence is committed, the highest allowed status is:

`IMPLEMENTATION_READY_FOR_SUPERVISOR_VISUAL_AUDIT`

## 12. Do not waste time on the dead path

Do not retry the public-grid private checkout with `github.token`. It was already proven to fail with:

`Repository not found`

Use the local authenticated private clone first.

If local execution becomes genuinely impossible, then the secure-grid path may be resumed, but only by supplying a private-repo credential through a GitHub Secret or by uploading an encrypted sparse bundle. Never publish private AASAL source plaintext into `windows-test-grid`.
