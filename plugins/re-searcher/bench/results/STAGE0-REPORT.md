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
- notes per rejected non-hard URL: wikipedia/github/rust-book/modelcontextprotocol.io
  are JS-or-nav-heavy (gate honest: thin-text / link-farm / script-shell);
  theverge.com/tech is a section index page — link-farm signal is correct, my corpus
  choice was the mistake (an article URL would likely store)
- urls.txt annotation errata: the stackoverflow line's human description said
  "split a string" but question id 643699 is numpy.correlate autocorrelation —
  fetch and storage behaved correctly; the comment was wrong.

## Claims study (Task 7)

(filled by Task 7)

## Go/No-Go

(filled by Task 7)
