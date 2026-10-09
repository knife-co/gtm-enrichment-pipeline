# Data Conflict Rule: Supabase vs Salesforce

**Supabase is the source of truth for machine-found data. Salesforce is where people work. When the two disagree, this rule decides.**

## The rule
1. **Human-edited Salesforce fields win.** If a field holds a value this pipeline did not write (someone typed it, or changed what we wrote), it is never overwritten. Logged as `human_value_kept`.
2. **Machine data defers to the more recent timestamp.** If Salesforce still holds the value we last wrote (or is empty), we update it only when our new value is newer than our last sync.
3. **Quality gate.** Accounts with doubtful identity (`needs_review`) or confidence below 60 are not synced at all (`held_for_review`). Accounts a person rejected are never synced.

## How a human edit is detected
For every field written, Supabase stores the exact value (`account_enrichment.sf_last_synced`). Before each sync, the pipeline reads Salesforce's current values:

| Salesforce now | What we last wrote | Decision |
|---|---|---|
| Empty | (nothing) | Fill it |
| Same as our new value | (any) | Nothing to do |
| Same as what we last wrote | X | Machine vs machine: update only if our data is newer |
| Different from what we last wrote | X | A person changed it: **keep theirs** |
| Has a value | (nothing; we never wrote it) | A person entered it: **keep theirs** |

No Salesforce field history tracking and no extra API calls are needed.

## Fields
`NumberOfEmployees`, `Industry` (mapped to the standard picklist), `Phone`, `Website`. `Data_Last_Verified__c` is set on every update.

## Where it lives
- `sf_sync_plan()` decides; `sf_sync_record()` remembers what was written.
- `sf_sync_log` records every decision: update / human_value_kept / held_for_review.
- `test_conflict_rule()`: 7 scenarios, 7 pass.
- Live test (9 Oct 2026): a phone number changed by hand in Salesforce was kept on the next sync.

## Why
Sales reps stop trusting a CRM the moment a robot overwrites something they fixed by hand. A pipeline that can't tell its own writes from a person's edits will eventually destroy someone's work.
