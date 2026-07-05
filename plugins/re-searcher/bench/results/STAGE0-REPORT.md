# Stage 0 benchmark report — Re:Searcher prototype slice

Date: 2026-07-05
Spec: docs/specs/2026-07-05-re-searcher-design.md (Roadmap item 0)

## Fetch/extraction benchmark (Task 6)

- usable-rate (17 non-hard URLs): 12/17 = **71%** (prediction: 60-75% — inside the band)
- hard URLs correctly gated: **3/3** (x.com, youtube, medium — all refused as low-confidence)
- confidence-gate false passes (stored but garbage on inspection): **0** of 5 inspected
- extraction quality eyeball (5 sources): anthropic.com engineering post **good**;
  MDN 302 **good**; arxiv abs **good** (header noise, abstract intact);
  overreacted.io **good**; stackoverflow **degraded** (banner/nav chrome ahead of
  content; question + answers present — right page, noisy head)
- notes per rejected non-hard URL (corrected by final review): wikipedia, github,
  modelcontextprotocol.io, and theverge were all refused by **`challenge-page`**, and
  at least Wikipedia is a FALSE refusal — `CHALLENGE_RE` substring-matches "Captcha"
  occurring in ordinary login/edit chrome while the page carried 43K chars of real
  article text. Only rust-book was a thin-text refusal. This bias is conservative
  (depresses usable-rate, never inflates it), so the benchmark numbers stand — but
  "challenge-page" detection is a defect class, not honest gating, for these four.
- additional Stage 1 recommendation: make challenge detection structural — require
  challenge signatures to co-occur with thin-text/short-title evidence (e.g. signature
  in <title> or textLength < 400) instead of a raw-HTML substring match; re-run the
  benchmark after the fix (expected usable-rate gain: +2-4 URLs).
- urls.txt annotation errata: the stackoverflow line's human description said
  "split a string" but question id 643699 is numpy.correlate autocorrelation —
  fetch and storage behaved correctly; the comment was wrong.

## Claims study (Task 7)

- claims: 30 across 5 sources / 5 domains (anthropic.com, developer.mozilla.org,
  arxiv.org, overreacted.io, paulgraham.com)
- exact: 16  normalized: 7  fuzzy: 6 (false groundings: **0** — all six sourceQuotes
  inspected and support their statements)  none: 1
- **verbatim-grounded rate (exact + normalized + honest fuzzy): 29/30 = 97%**
- failure causes:
  - all 6 fuzzy = markdown link markup in the extraction (`[SEO](/docs/...)`) vs plain
    transcription ("SEO") — honest matches, correctly relocated to real source bytes;
    one sourceQuote clipped mid-link ("use [303 See") by the window trim — supports the
    claim but ugly
  - the 1 none = same markup class at higher density: `**302 Found**` bold + an inline
    link INSIDE the quoted span defeated LCS coverage — an honest FALSE NEGATIVE, not a
    false positive
- caveat: operator transcription (Claude typing from reading) is cleaner than worst-case
  agent noise, but the observed failure mode is structural (markup mismatch), not
  transcription sloppiness — and it is deterministic to fix
- Stage 1 recommendation derived from the data: vault-save's quote verification should
  match against a markdown-stripped plain-text view of the extraction (strip `**`,
  `[text](url)` → text, backticks) before the existing normalize ladder; this converts
  the entire observed failure class (7/30 claims demoted to fuzzy/none) into
  exact/normalized matches. Also: widen the fuzzy window trim to whole-link boundaries
  so sourceQuotes never clip mid-link.

## Go/No-Go

Rule (pre-committed in the plan): >=60% verbatim-grounded AND usable-rate >=60% -> GO.

Result: **GO — build Stage 1 as designed.**
- usable-rate 71% (12/17, inside the predicted 60-75% band), 3/3 hard URLs gated, 0
  gate false passes on inspection
- verbatim-grounded 97% (29/30), 0 false groundings
- The core promise holds: raw fetch + deterministic quote verification can ground
  claims in cached sources at rates far above the GO threshold. The one systematic
  weakness (markdown markup defeating matches) is a deterministic normalization fix,
  already specified above as a Stage 1 requirement.
