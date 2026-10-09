# GTM Enrichment Pipeline (P2)

A waterfall enrichment pipeline that fills in company data **cheapest source first**, stops as soon as an account is complete, checks the data belongs to the right company, and syncs to Salesforce under a written conflict rule where **a person's edit always wins**.

Built on a $0 stack: **n8n**, **Supabase (Postgres)**, **Salesforce Developer Edition**, Apollo's free tier (75 credits) and companies' own websites. Second project in my GTM Engineering portfolio. It enriches the accounts found by [gtm-icp-engine](https://github.com/knife-co/gtm-icp-engine) (P1).

## Results

**Before/after on the same 70 benchmark accounts:**

| | Apollo only | Waterfall v1 | Production pipeline |
|---|---|---|---|
| Any data found | 91.4% | **97.1%** | 97.1% |
| Size + industry + LinkedIn ("complete") | 91.4%* | 90.0% | **88.6% verified** |
| LinkedIn page | 91.4% | 97.1% | **94.3%** |
| Phone | 70.0% | 75.7% | 72.9% |
| Credits spent | 64 | 64 | **0** on a re-run (cache) |
| Wrong-company data in Salesforce | not checked | not checked | **0** (2 caught and rejected) |

\*Apollo's 91.4% includes 2 companies it matched to **the wrong business** (by domain): a UK snowboard shop and a German energy firm. The production pipeline catches these with identity checks, so its lower "complete" number is the honest one.

**First production run (90 accounts, 11 min):** 70 enriched, 14 partial, 6 unenriched (each with a written reason). 65 stopped at the free cache tier. 10 Apollo credits used, then the budget guard stopped at exactly 75/75. 50 Salesforce fields written, 0 failures, **0 human edits overwritten**.

**Live conflict-rule test:** I changed an account's phone number by hand in Salesforce, then re-ran the sync. The pipeline recognised the human edit and kept it (`human_value_kept`). The same run updated 0 other fields, so re-running is safe.

## How it works

```
Fetch stale / unenriched accounts   (never enriched · partial >7 days · anything >90 days)
  → Tier 1  Cache (Supabase)           free    hit (complete)? stop
  → Tier 2  Company website            free    /, /about, /contact, /team; stops if blocked
  → Tier 3  Hunter                     25/mo   off: free tier requires a work email
  → Tier 4  Apollo                     1 credit per company found; breaker + monthly budget
  → Tier 5  Email pattern guess        free    labelled "unverified"
  → nothing worked? mark unenriched + log why
  → normalize → resolve identity → score confidence (0–100)
  → Supabase golden record (truth) + raw results (cache)
  → Salesforce sync under the conflict rule
  → one data quality report row per run
```

- **"Complete"** = employee count + industry + LinkedIn page. Every tier first checks this: hit? stop.
- **Negative caching:** a website read in the last 30 days, or an Apollo "no match", is not asked again.
- **Normalize:** provider industries → Salesforce's standard Industry picklist (lookup table), one phone format, canonical LinkedIn URLs, employee bands.
- **Identity resolution:** the name a provider returns is fuzzy-matched against ours. A mismatch means `needs_review`, confidence is capped at 50, and the account is not synced.
- **Confidence (explainable):** +20 high-confidence domain, +30 identity confirmed, +20 LinkedIn page name matches, +10 website reachable, +20 complete.
- **Human review:** `identity_reviews` table. *Approve* syncs the account. *Reject* wipes the wrong data and stops re-enrichment until the company gets a different domain.
- **Reliability (from earlier this week):** per-provider circuit breaker, exponential backoff with jitter, a replayable dead-letter queue, and a monthly credit budget per provider.

## The conflict rule

1. **Human-edited Salesforce fields win.** They are never overwritten.
2. **Machine data defers to the more recent timestamp.**
3. **Doubtful identity is held back** (`needs_review` or confidence < 60).

Human edits are detected **without Salesforce field history**: Supabase stores the exact value the pipeline last wrote to each field. If Salesforce now shows something else, a person changed it. Full write-up: [docs/conflict-rule.md](docs/conflict-rule.md). Tested by `test_conflict_rule()`: 7/7 scenarios pass.

## Tests

| Test | Result |
|---|---|
| `test_reliability_layer()`: circuit breaker, email risk, dead-letter replay | 20/20 |
| `test_conflict_rule()`: Supabase vs Salesforce decisions | 7/7 |
| Company name matching pairs (Day 1) | 16/16 |
| Live human-edit test in Salesforce | kept ✅ |

All SQL tests run inside a savepoint and roll back, so they leave no test data behind.

## What didn't work (and what replaced it)

| Tried | Problem | Outcome |
|---|---|---|
| Apollo for 200 accounts | Free plan = 75 credits | Benchmark cut to 70 (stated openly); the Apollo step replays saved answers for fair comparisons |
| Expecting the waterfall to save credits | Websites never publish headcount | It added fields (LinkedIn, phone), not savings, on a first run; savings come from the cache on re-runs |
| Scraped emails as contacts | 22 found, **0 were people** (info@, privacy@, junk) | Stricter email-risk rules; person emails need a contact source (Hunter) |
| Hunter | Free tier refuses Gmail sign-ups | Tier built and switched off, to be enabled with a work email |
| Trusting "matched" | Apollo enriched the wrong company where our domain was wrong | Identity checks + human review queue |

## Repository

```
sql/schema.sql          every P2 table, view and function, in the order applied (needs the P1 schema)
workflows/              n8n exports (credentials and instance URLs removed)
  1-enrichment-pipeline-production.json   the full pipeline (scheduled daily)
  2-waterfall-v1-comparison.json          the comparison run against the Apollo baseline
  3-apollo-only-baseline.json             the "before" measurement
  4-salesforce-sync-only.json             re-check Salesforce without enriching
  5-dead-letter-replay.json               replays failed work with backoff + breaker
docs/conflict-rule.md   the written conflict rule
```

## Run it yourself
1. Set up P1 ([gtm-icp-engine](https://github.com/knife-co/gtm-icp-engine)), then run `sql/schema.sql` in Supabase.
2. In Salesforce, add the Account field `Data_Last_Verified__c` (Date), plus `Domain__c` from P1.
3. Import the workflows into n8n. Connect a Supabase credential, a Salesforce JWT credential and an "Apollo API" Header Auth credential (`X-Api-Key`). Replace `YOUR_PROJECT_REF` and `YOUR_INSTANCE` in the HTTP nodes.
4. Run the production pipeline, or let its daily schedule run it.

Company domains come from P1. Company data comes from Apollo.io (free tier) and companies' own public websites, read politely (4 pages max, identified user agent, no bypassing of blocks). This repository contains no enriched data, only the pipeline.
