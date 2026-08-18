# NEXT and Current State Specification

## Purpose

Defines NEXT as an appended record rather than an edited section — the most recent one is current, all
earlier ones are retained as history — and defines the current state as a rendering of that narrative
together with the items still open.

## Requirements

### Requirement: NEXT is an appended record, not an edited section

A NEXT record SHALL be appended like any other record. The most recently appended NEXT SHALL be the
current one. Earlier NEXT records SHALL be retained as history. No NEXT record SHALL ever be rewritten in
place.

#### Scenario: Updating what comes next

- **WHEN** the architect records a new NEXT
- **THEN** it is appended, it becomes current, and the previous NEXT remains in the history unaltered

#### Scenario: Reading the current NEXT

- **WHEN** an agent asks for the current NEXT
- **THEN** it receives the most recently appended one and no other

#### Scenario: Tracing how the plan changed

- **WHEN** an agent asks for the history of NEXT records
- **THEN** every NEXT ever recorded is available in order

### Requirement: A NEXT body is a short narrative

A NEXT body SHALL carry only narrative that cannot be derived — the resume point and what to tackle next.
It SHALL NOT be the place where open questions, deferred items, findings, or status grids are restated,
because those are derived from the items themselves.

#### Scenario: Tracked state is not retyped

- **WHEN** the architect records a NEXT while several items are open
- **THEN** it writes only the narrative, and the open items are not repeated in the body

### Requirement: The current state is rendered from the narrative plus the open items

The tool SHALL present the current state by combining the current NEXT narrative with the items that are
currently open. Because the item portion is derived on every read, it SHALL NOT be capable of drifting
from the actual state of the items.

#### Scenario: Presenting current state

- **WHEN** an agent asks for the current state
- **THEN** it receives the current NEXT narrative together with the currently open items

#### Scenario: Closing an item changes what is presented

- **WHEN** an open item is closed and no new NEXT is recorded
- **THEN** the next presentation of current state no longer lists that item

#### Scenario: Blocking items are distinguishable

- **WHEN** the current state is presented and some open items are flagged as blocking
- **THEN** those items are distinguishable from the non-blocking ones
