# Durable Format Specification

## Purpose

Defines `DEVLOG.jsonl` as the single, authoritative, version-controlled source of truth for a change's
working channel: a precisely specified and versioned record format, no state held anywhere outside that
file, an explicitly named target change, and serialised writes so concurrent agents cannot corrupt it.

## Requirements

### Requirement: The line-delimited file is the source of truth

`DEVLOG.jsonl` SHALL be the authoritative record of the change's working channel. It SHALL be committed
to source control and SHALL travel into the OpenSpec archive with the change. Any working index the tool
maintains SHALL be treated as derived data.

#### Scenario: The file is the record that persists

- **WHEN** the change is archived
- **THEN** `DEVLOG.jsonl` is part of the archived change

#### Scenario: Every write reaches the durable file

- **WHEN** a record is written
- **THEN** it is present in `DEVLOG.jsonl` without any further command being required

### Requirement: The record format is precisely specified and versioned

The structure of a record SHALL be specified precisely enough that the file can be reconstructed into a
working index without ambiguity. The file SHALL record the format version and the version of the tool
that wrote it, so that a later version can recognise what it is reading.

#### Scenario: A later version reads an older file

- **WHEN** a version of the tool opens a file written by an earlier version
- **THEN** it can determine the format version and the writing tool's version from the file itself

#### Scenario: An unrecognised format version

- **WHEN** the tool opens a file whose format version it does not understand
- **THEN** it reports this clearly rather than misreading the contents

### Requirement: No state exists outside the log file

The tool SHALL hold no persistent state anywhere but `DEVLOG.jsonl`. Everything it needs — records,
item numbering, item states, references, and any index used to answer a query — SHALL be derived from
that file on each invocation and discarded when the process exits.

One exception, and only one: a write MAY create a single temporary file in the same directory as
`DEVLOG.jsonl`, for the duration of that write and no longer, solely so that the log can be replaced
atomically and never observed in a partial state. It SHALL be removed before the command exits, whether
the write succeeded or failed, and it SHALL NOT be read by any command — it is a write mechanism, not
state. This exception exists because atomic replacement cannot be achieved without it, and the guarantee
it buys — that no reader ever sees a torn record — is worth more than the invariant it costs.

#### Scenario: Nothing to rebuild

- **WHEN** the repository is cloned fresh, containing only the committed file
- **THEN** every command works immediately, with no initialisation, import, or index-building step

#### Scenario: Identical answers from identical files

- **WHEN** the same log file is read on two different machines
- **THEN** every record, item number, derived state, and reference resolves identically

#### Scenario: No stray files are produced

- **WHEN** any command completes, successfully or not
- **THEN** no file other than `DEVLOG.jsonl` exists that the command created
- **AND** no file other than `DEVLOG.jsonl`, and the write's own temporary file, has been modified or
  deleted

#### Scenario: A write's temporary file does not outlive it

- **WHEN** a write completes, successfully or not
- **THEN** the temporary file it used to replace the log atomically no longer exists

#### Scenario: A read ignores a temporary file

- **WHEN** a temporary file is present from a write that was killed before it could clean up
- **THEN** no command reads it, and it is not mistaken for the log

### Requirement: The change being operated on is named explicitly

The path to the change's log file SHALL be supplied as a parameter, so the tool operates on one change at
a time and never guesses which change is meant.

#### Scenario: Operating on a specific change

- **WHEN** an agent invokes the tool with the path to a change's log file
- **THEN** the command applies to that change alone

#### Scenario: A missing log file

- **WHEN** the given path does not exist and the command is a read
- **THEN** the tool reports plainly that the change has no log yet, rather than creating one silently

### Requirement: Writes are serialised

The tool SHALL take a lock for the duration of a write, so that two concurrent invocations cannot
interleave and corrupt the record. Agents run in series today; this requirement exists so that ceasing to
do so does not corrupt a log.

#### Scenario: Two writers at once

- **WHEN** a second invocation attempts to write while a first is writing
- **THEN** it waits for the first to finish, and both records are written intact and in a definite order

#### Scenario: A write interrupted part-way

- **WHEN** a write does not complete
- **THEN** the file does not contain a partial record
