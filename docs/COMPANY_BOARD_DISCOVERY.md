# Bounded company board expansion

The October 10, 2026 source batch adds ten public Greenhouse boards to the
existing collector: Datadog, Figma, Robinhood, Discord, MongoDB, Duolingo,
Pinterest, Affirm, Asana, and Vercel. These sources broaden technology employer
coverage for entry-level software and upcoming graduate hiring, while retaining
all other occupations and existing general matching.

Each configured board returned normalized listings through the existing
unauthenticated Greenhouse adapter during read-only verification. Ramp and
Notion did not pass that check and are excluded. The ten boards returned 1,837
normalized records in that check; this is not a unique, US-only, entry-level,
2027-specific, or production-import count.

No new adapter, paid provider, credential, browser renderer, or recursive crawl
is introduced. Existing six-hour source scheduling, resumable leases, transport
limits, canonical deduplication, source observations, closure handling, and retry
behavior apply. The bounded initial refresh is one existing worker lease for
each of the ten exact source IDs, with a 180-second service runtime per lease.
Partial sources resume through existing persisted checkpoints and scheduling.

Validate the JSON source IDs are unique and run the existing discovery suites.
After the reviewed source release, verify per-source success and catalog
freshness through the private discovery-report API, and verify the Jobs feed
through an existing authenticated account. Do not infer feed acceptance solely
from catalog counts or classify every new record as an early-career match.
