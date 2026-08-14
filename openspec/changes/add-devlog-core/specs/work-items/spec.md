## ADDED Requirements

### Requirement: Agents can raise work items

The tool SHALL let any role raise a work item. An item SHALL have a kind drawn from: question, finding,
decision, note, and task. An item MAY name an addressee — the role expected to act on it — and MAY be
flagged as blocking. The blocking flag SHALL be independent of the kind, so that any kind of item can
block.

#### Scenario: Raising a question for another role

- **WHEN** a worker raises a question addressed to the architect
- **THEN** the item is recorded as a question, addressed to the architect, and open

#### Scenario: A blocking decision

- **WHEN** an item is raised as a decision and flagged as blocking
- **THEN** it is recorded as blocking, and its kind remains decision

#### Scenario: A note that blocks nothing

- **WHEN** an observation is recorded as a note without a blocking flag
- **THEN** it is open but not blocking, and it needs no addressee

### Requirement: Items get short, quotable identifiers

The tool SHALL assign every item an identifier that is short enough to quote naturally in prose. The
identifier SHALL be unique within the change and SHALL be stable for the life of the item.

#### Scenario: An identifier is returned on creation

- **WHEN** an item is raised
- **THEN** the tool returns its identifier so the author can cite it in later prose

#### Scenario: Citing an item in a later record

- **WHEN** a later record's prose refers to an item by its identifier
- **THEN** the identifier still resolves to the same item

### Requirement: Items are closed by a separate close record

Closing an item SHALL be recorded as its own record rather than by altering the item. A close record
SHALL carry the closing author and a comment explaining the closure. An item's state SHALL be derived
from its opening record together with any close records, and SHALL be one of: open, resolved, deferred,
or superseded.

A close SHALL name an item that has actually been raised, and a close naming an identifier no item bears
SHALL be refused. The reasoning is the addressee's: a mistyped identifier produces a close record that
closes nothing, while the item it was meant to close stays open forever and nothing anywhere reports a
fault. Everything downstream may therefore rely on every stored close naming a real item.

Closing an item that is already closed SHALL NOT be refused. The log is append-only and a correction is
expressed by appending a further record, so an item closed as deferred and later resolved is an ordinary
sequence rather than an error. Which closure is current is a question about deriving state, answered by
the ordering the log already carries, not a question the write is entitled to refuse.

#### Scenario: Closing an item with an explanation

- **WHEN** an item is closed with a comment
- **THEN** the close is appended as a record, the original item is unaltered, and the item's derived state
  reflects the closure

#### Scenario: A closure always carries a reason

- **WHEN** an attempt is made to close an item without a comment
- **THEN** the tool rejects the close and explains that a reason is required

#### Scenario: Deferring rather than resolving

- **WHEN** an item is closed as deferred
- **THEN** its derived state is deferred, distinguishable from resolved

#### Scenario: The closure record is attributable later

- **WHEN** a closed item is inspected
- **THEN** who closed it, when, and why are all recoverable

#### Scenario: Closing an item that was never raised

- **WHEN** a close names an identifier that no item bears
- **THEN** the tool rejects the close and reports how many items exist
- **AND** the log is unchanged, so no record is stored closing an item that does not exist

#### Scenario: Closing an item that is already closed

- **WHEN** an item closed as deferred is later closed as resolved
- **THEN** both close records are appended, and neither is refused

### Requirement: Only a declared closing role may close an item

The `header` SHALL declare which of the project's roles may close items. The tool SHALL refuse a close
from any role not so declared. This SHALL be a guardrail rather than a security boundary: the calling role
is self-declared and unverified, so the tool SHALL make the correct path the easy one while the
documentation SHALL state plainly that the restriction relies on agents honouring it.

Every role declared as a closer SHALL also be one of the project's declared roles, and a declaration
naming a closer that is not a declared role SHALL be refused. A closer outside the role set could never
write a close record in the first place, since every write is already held to the declared roles — so such
a declaration is not a permission being granted, it is a typo that reads like one.

The closing role SHALL be named by the project rather than fixed by the tool, consistent with the role set
itself being declared per project.

#### Scenario: A worker attempts to close an item

- **WHEN** a worker tries to close an item and is not a declared closing role
- **THEN** the tool refuses and explains which roles may close items

#### Scenario: A reviewer signals rather than closes

- **WHEN** a reviewer is satisfied that a finding it raised has been addressed
- **THEN** it records that judgement, and the item remains open until a declared closing role closes it

#### Scenario: The limits of the guardrail are documented

- **WHEN** a reader consults the documentation about who may close items
- **THEN** it states that roles are self-declared and the restriction is not enforced
