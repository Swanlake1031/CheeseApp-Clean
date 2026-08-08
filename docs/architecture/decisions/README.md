# Architecture Decision Records

This directory stores concise architecture decision records for Cheese App.

Create an ADR only when a decision changes module ownership, dependency direction, data modeling, release order, or long-term extensibility. Do not create ADRs for routine code edits.

## ADR Template

```md
# ADR-NNNN: Title

Status: Proposed | Accepted | Superseded | Deprecated

Date: YYYY-MM-DD

## Context

What problem or force made this decision necessary?

## Decision

What decision are we making?

## Alternatives Considered

- Alternative A: why not
- Alternative B: why not

## Consequences

Positive and negative consequences.

## Affected Modules

Which app, database, worker, or docs areas are affected?

## Migration Plan

How existing code/data moves to this decision.

## Validation Plan

How we know the decision is correctly implemented.
```

## Current ADRs

- [ADR-0001: Active Product Module Boundary](0001-active-product-module-boundary.md)
- [ADR-0002: Base Post With Feature Detail Tables](0002-base-post-with-feature-detail-tables.md)
- [ADR-0003: Supabase Access Boundary](0003-supabase-access-boundary.md)
- [ADR-0004: Courses V1 Domain Contract](0004-courses-v1-domain-contract.md)
