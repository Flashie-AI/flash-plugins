---
_schema:
  entity_type: person
  required: [type, role, team, updated]
  optional: [squad]
  constraints:
    updated: "YYYY-MM-DD"
type: person
role: <role title>
team: <functional team slug>
# squad: YAML list — one or many slugs. Example: [billevers] or [billevers, mercury]
squad: [<squad slug>]
updated: YYYY-MM-DD
---

# <Full name>

One sentence: role, squad, and anchor.

## Owns
- <area of responsibility>

## Background
Prior companies, expertise areas, domain depth.

## Working style
How to collaborate with this person. Comms preferences, strengths, pairings.
