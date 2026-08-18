# Log Retrieval Specification

## Purpose

Defines how the log is read back: a single bounded read that lets a cold agent orient itself, direct
lookup by identifier or reference, search by meaning, narrowing by section, block, role, kind, and
state, and every read available both rendered for humans and machine-readable for agents.

## Requirements

### Requirement: An agent starting cold can orient itself in one read

The tool SHALL provide a single read that gives an agent what it needs to resume work: the items
currently open and addressed to that agent, together with the current state as rendered from the NEXT
narrative and the open items. The size of this read SHALL be bounded by what is currently open rather
than by the length of the log's history.

#### Scenario: A worker resumes a change

- **WHEN** a worker asks for its starting context
- **THEN** it receives the open items addressed to it and the current state, and nothing else

#### Scenario: The read does not grow with history

- **WHEN** the log has accumulated a large number of records but few items are open
- **THEN** the starting read remains small

#### Scenario: Items for other roles are excluded

- **WHEN** items are open and addressed to other roles
- **THEN** they do not appear in this agent's starting read

### Requirement: Anything can be reached by identifier or reference

The tool SHALL retrieve a record or an item directly by its identifier, and SHALL retrieve records by the
external references they carry, so that a citation encountered in prose can always be followed without
reading the surrounding log.

#### Scenario: Following a citation

- **WHEN** an agent encounters an item identifier quoted in a body
- **THEN** it can retrieve that item, its current state, and its closure if it has one

#### Scenario: Following an external reference

- **WHEN** an agent needs the discussion around an external identifier
- **THEN** it retrieves the records carrying that reference without reading the whole log

### Requirement: The log can be searched by meaning

The tool SHALL support searching the log for records relevant to a question expressed in natural
language, so that an agent can find what was decided about a topic without ingesting the log. Search
SHALL be scoped to a single change.

#### Scenario: Asking what was decided about a topic

- **WHEN** an agent searches for a topic discussed in earlier records
- **THEN** it receives the relevant records rather than the entire log

#### Scenario: Search stays within one change

- **WHEN** an agent searches
- **THEN** only records belonging to the change being searched are considered

### Requirement: Reads can be narrowed by section, block, role, kind, and state

The tool SHALL let a reader narrow what is returned along the dimensions the workflow uses, so that a
reader can ask a precise question and receive a precise answer.

#### Scenario: One section's thread

- **WHEN** an agent asks for the records of a single section
- **THEN** only that section's records are returned, in order

#### Scenario: All open blocking items

- **WHEN** an agent asks for items that are open and blocking
- **THEN** only those items are returned, regardless of kind or addressee

### Requirement: Role and addressee filters validate against the right header scope

The tool SHALL validate a `role` or addressee (`to`) filter against the log's declared role set before
using it to narrow a read, so that a filter naming a role that was never declared fails loudly rather
than silently returning nothing. Which declaration a filter is validated against SHALL depend on what
the read is answering: a read of the project's *current* identity SHALL validate against the **latest**
header only, while a read of the project's *history* SHALL validate against the **union of every role
ever declared** across every header in the log, so that a role retired from a later header remains a
valid filter for a search of the log's past.

#### Scenario: Resuming validates against the current role set only

- **WHEN** a worker resumes with `--role <r>` and `<r>` was declared by an earlier header but has since
  been retired from the latest header
- **THEN** the resume is refused, because resuming is a claim about the project's current identity

#### Scenario: Listing or searching accepts a retired role

- **WHEN** an agent lists or searches with `--role <r>` or `--to <r>`, and `<r>` was declared by an
  earlier header but has since been retired from the latest header
- **THEN** the read succeeds and returns the records that role authored or was addressed to, because
  listing and searching answer questions about the log's whole history

#### Scenario: An undeclared role is refused everywhere

- **WHEN** any read filter names a role that was never declared by any header in the log
- **THEN** the read is refused, regardless of which header scope that read validates against

### Requirement: Every read is available both rendered and machine-readable

Each read SHALL present its result as rendered text by default, for a reader working in a terminal or
quoting the result into prose, and SHALL present the same result as JSON when asked, for a consumer that
parses it. Both SHALL be produced from one derivation, so that the rendered and machine-readable forms can
never report different things about the same log.

#### Scenario: Reading in a terminal

- **WHEN** an agent or a person performs a read without asking for JSON
- **THEN** the result is rendered as text meant to be read, and can be quoted directly into a record's
  prose

#### Scenario: A consumer parses a read

- **WHEN** a program performs the same read asking for JSON
- **THEN** it receives the result as JSON on standard output

#### Scenario: The two forms agree

- **WHEN** the same read is performed in both forms against an unchanged log
- **THEN** they describe the same records, items and state, differing only in presentation
