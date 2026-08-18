# External References Specification

## Purpose

Defines how a record carries structured references to identifiers that live outside the log — design
decisions, spec requirements, scenarios, and any other numbering a change adopts. References are a
free-form namespace plus an identifier, are queryable, and are never validated by the tool.

## Requirements

### Requirement: Records can carry structured references to external identifiers

A record SHALL be able to carry references to identifiers that live outside the log — design decisions,
spec scenarios, requirements, and anything else the change numbers. A reference SHALL be a namespace and
an identifier, with the namespace free-form so that any convention a change adopts is supported without
the tool being changed.

#### Scenario: Referencing a design decision

- **WHEN** a record is written referring to a design decision in a namespace the change uses
- **THEN** the reference is stored as structured data alongside the record, not merely as prose

#### Scenario: A namespace the tool has never seen

- **WHEN** a change adopts a new namespace for its identifiers
- **THEN** references in that namespace are accepted without configuration or code changes

#### Scenario: Several references on one record

- **WHEN** a record concerns more than one external identifier
- **THEN** all of the references are recorded against it

### Requirement: References are queryable

The tool SHALL be able to return every record carrying a given reference. This SHALL be an exact match on
the structured reference, not a text search of bodies.

#### Scenario: Finding everything that touches one decision

- **WHEN** an agent asks for all records referencing a particular external identifier
- **THEN** every record carrying that reference is returned, and records that merely mention the
  identifier in prose without recording it as a reference are not

### Requirement: References are not validated

The tool SHALL NOT attempt to verify that a referenced identifier exists, because the referenced material
lives outside the log. A reference to something that does not exist SHALL be accepted and stored.

#### Scenario: Referencing something that does not exist

- **WHEN** a record references an identifier that has no counterpart anywhere
- **THEN** the tool accepts it without error and without warning
