## ADDED Requirements

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
