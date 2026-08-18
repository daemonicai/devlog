## ADDED Requirements

### Requirement: The log is append-only

The log SHALL only ever grow. Writing SHALL add a new record; the tool SHALL NOT provide any means of
modifying or deleting a record that has already been written. Corrections and state changes SHALL be
expressed as further records that refer to the earlier one.

#### Scenario: A record cannot be edited

- **WHEN** an agent wants to change something it previously recorded
- **THEN** the tool offers no command that rewrites or removes the earlier record
- **AND** the correction is expressed by appending a new record referring to it

#### Scenario: History survives every later write

- **WHEN** any number of later records have been written
- **THEN** every earlier record is still present, unaltered, in its original order

### Requirement: Every record is attributed to a role

Every record SHALL carry the role that wrote it. The set of roles SHALL be declared per project rather
than fixed by the tool, so that a project can name whatever participants its workflow actually has. The
declared set SHALL live in the log's own `header` record, so a log carries its own vocabulary and an agent
reading it cold needs nothing external to interpret attribution.

A write whose role is not in the declared set SHALL be rejected, naming the declared roles. The
flexibility is in what a project may declare, not in whether a writer may invent a role at the point of
writing — an undeclared role is far more often a typo that would silently fragment attribution than a
genuine new participant.

A record's **addressee** SHALL be held to the same declared set as its author, and a write naming an
addressee the header never declared SHALL be rejected in the same way. The reasoning is the writer's
reasoning one field over: an addressee is a role name, a mistyped one is far more often a typo than a new
participant, and the failure it produces is worse than a mistyped author's rather than better. A record
attributed to a misspelt author is at least visibly misattributed; a record *addressed* to a misspelt role
is addressed to nobody, and every derived per-role view — the open items a role must act on, the latest
brief for its block — silently omits it. The record is in the log, correctly stored, and invisible to the
one participant it was written for.

The `header` record SHALL be exempt from attribution, because it is the record that establishes the
declared set: requiring it to carry a role drawn from the set it is itself declaring cannot be satisfied
for the first header in a log.

The declaration SHALL be a **set**: two declarations naming the same roles differ only if the roles
themselves differ, and the order they are named in SHALL NOT constitute a change. A declaration naming the
same role twice SHALL be refused rather than stored, because a repeated name is a typo in every case that
matters and storing it would make the tool report its own declared roles back with a duplicate in them.
This matters because re-declaring appends: a log is append-only, so treating a reordering as a change
grows the file with a record that means nothing, and an agent re-running `devlog header` defensively
should be able to rely on an unchanged declaration writing nothing at all.

#### Scenario: Attribution is required

- **WHEN** an agent writes a record of any kind other than `header` without stating its role
- **THEN** the tool rejects the write and explains that attribution is required

#### Scenario: The header carries no role

- **WHEN** the record declaring the project's roles is written
- **THEN** it is accepted without a role, since it is what establishes which roles exist

#### Scenario: A project declares its own roles

- **WHEN** a project declares a role set naming the participants of its workflow
- **THEN** every declared role may write records, whatever those roles are named

#### Scenario: Re-declaring the same roles in a different order

- **WHEN** a declaration names exactly the roles already declared, in a different order
- **THEN** nothing is appended, because the declaration has not changed

#### Scenario: A declaration naming the same role twice

- **WHEN** a declaration names the same role more than once
- **THEN** the tool rejects it rather than storing a duplicate

#### Scenario: A per-stack worker is distinguishable

- **WHEN** a project declares a worker specialised to a stack and that worker writes a record
- **THEN** the record identifies that specific worker, not merely "a worker"

#### Scenario: An undeclared role is refused

- **WHEN** an agent writes a record with a role the header never declared
- **THEN** the tool rejects the write and reports which roles are declared

#### Scenario: An undeclared addressee is refused

- **WHEN** an agent writes a record addressed to a role the header never declared
- **THEN** the tool rejects the write and reports which roles are declared
- **AND** the log is unchanged, so no record is stored addressed to a role that does not exist

### Requirement: Records reference the work they concern

A record SHALL be able to name the section and the block of tasks it concerns, so that the log can be
read by section and by block rather than only in sequence.

#### Scenario: Reading one section

- **WHEN** an agent asks for the records belonging to one section
- **THEN** only that section's records are returned

#### Scenario: A record spanning several tasks

- **WHEN** a record concerns a block covering more than one task
- **THEN** the record captures the whole block, not just a single task

### Requirement: Bodies are Markdown supplied on standard input

The prose of a record SHALL be supplied on standard input rather than as a command-line argument, and
SHALL be stored exactly as supplied. The tool SHALL NOT parse, reformat, or reinterpret a body. Everything
the tool reasons about SHALL be explicit metadata supplied alongside the body.

A body SHALL be valid UTF-8, and a write whose body is not SHALL be refused before anything is written.
This is the one property of a body the tool inspects, and it exists to keep a stronger promise: **the tool
SHALL NOT write a record it cannot read back**. Storing a body it could not later parse would corrupt the
log permanently, since the log is append-only and has no repair path. Refusal is the narrower failure.

#### Scenario: A long body with Markdown structure

- **WHEN** a body containing headings, emphasis, tables, and fenced code blocks is supplied on standard
  input
- **THEN** it is stored verbatim and reproduced unchanged when read back

#### Scenario: Body content never changes behaviour

- **WHEN** a body contains text resembling a command, an identifier, or a status marker
- **THEN** the tool treats it as prose and derives no meaning from it

#### Scenario: A body that is not valid UTF-8

- **WHEN** a body containing bytes that are not valid UTF-8 is supplied on standard input
- **THEN** the write is refused with a clear message
- **AND** the log is unchanged, byte for byte

#### Scenario: A body of valid non-ASCII text

- **WHEN** a body containing accented letters, CJK characters, or emoji is supplied
- **THEN** it is stored and reproduced unchanged, like any other body

### Requirement: Records have a definite order

Records SHALL have a single, unambiguous order that is preserved across a rebuild of any working index,
so that "the most recent record of a kind" is always well defined.

#### Scenario: Determining the latest record

- **WHEN** several records of the same kind exist
- **THEN** exactly one is identifiable as the most recent

#### Scenario: Order survives reconstruction

- **WHEN** the working index is discarded and rebuilt from the durable file
- **THEN** the order of records is identical to before
