# Backend Development Guidelines

> Best practices for backend development in this project.

---

## Overview

This directory contains guidelines for backend development. Fill in each file with your project's specific conventions.

---

## Guidelines Index

| Guide | Description | Status |
|-------|-------------|--------|
| [Agent Bridge Private Relay](./agent-bridge-private-relay.md) | Direct-first transport, credential boundaries and relay lease lifecycle | Current |
| [Agent Bridge Host](./agent-bridge-host.md) | Current embedded daemon, ABP, pairing, process ownership and byte relay | Current |
| [Agent Bridge Control](./agent-bridge-control.md) | Historical server-side business-state architecture | Superseded for current host |
| [Agent Bridge Phase 0](./agent-bridge-phase0.md) | Native protocol and evidence contract | Implemented |
| [Directory Structure](./directory-structure.md) | Module organization and file layout | To fill |
| [Database Guidelines](./database-guidelines.md) | ORM patterns, queries, migrations | To fill |
| [Error Handling](./error-handling.md) | Error types, handling strategies | To fill |
| [Quality Guidelines](./quality-guidelines.md) | Code standards, forbidden patterns | To fill |
| [Logging Guidelines](./logging-guidelines.md) | Structured logging, log levels | To fill |

---

## How to Fill These Guidelines

For each guideline file:

1. Document your project's **actual conventions** (not ideals)
2. Include **code examples** from your codebase
3. List **forbidden patterns** and why
4. Add **common mistakes** your team has made

The goal is to help AI assistants and new team members understand how YOUR project works.

---

**Language**: All documentation should be written in **English**.
