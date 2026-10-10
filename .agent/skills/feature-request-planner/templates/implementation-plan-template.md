# Feature Implementation Plan: [Feature Title]

> **Status**: Ready for Implementation / Handoff  
> **Evaluated By**: Feature Viability & Planning Agent  
> **Date**: [YYYY-MM-DD]  
> **Approved Scope**: [Short summary of the approved capability and approach]

---

## 1. Overview & Architectural Rationale

### 1.1 Context & Problem
[Concise explanation of the validated use case and why this feature is being added.]

### 1.2 Chosen Solution & Architectural Alignment
[Explain the selected design and why it fits cleanly into the existing codebase architecture. If this differs from the user's initial proposal, explain why this alternative is superior.]

### 1.3 Key Constraints & Rules
- [List project-specific rules, e.g., zero edits to upstream vendor dependencies per `AGENTS.md`]
- [Backward compatibility constraints]
- [Security, permission, or execution context constraints]

---

## 2. Codebase Impact & File Placement

### 2.1 File Placement Map
Define exactly where the new logic lives to avoid shoehorning code into inappropriate layers:

| Layer / Role | Target File(s) | Change Type | Purpose |
| :--- | :--- | :--- | :--- |
| **Backend / Wrapper** | `path/to/script` | Modify / Create | [Core logic, validation, execution] |
| **Configuration / State**| `path/to/config` | Modify / Schema | [Configuration persistence, defaults] |
| **WebGUI / Presentation**| `path/to/page.page` | Modify / Create | [User interface inputs, status display] |
| **Hooks / Integration** | `path/to/hooks` | Modify | [System lifecycle event hooks] |
| **Tests** | `t/test_name.t` | Create / Modify | [Automated regression and unit tests] |

### 2.2 Integration Points in Existing Code
*   **Trigger / Entry Point**: `[File:Function or Hook]` — [Describe how control flows into the new feature]
*   **State Management**: `[Config / INI / JSON]` — [Describe schema changes, defaults, and migration paths]
*   **Upstream / Downstream Boundaries**: [How this interfaces with external dependencies or wrappers without modifying upstream code]

---

## 3. Phased Implementation Tasks

Break the work down into self-contained, verifiable phases ready for execution by an implementation agent or engineer.

### Phase 1: Core Logic & Backend Infrastructure
- [ ] Task 1.1: [Specific actionable task with exact file target]
- [ ] Task 1.2: [Data validation, boundary guards, and error handling]
- [ ] Task 1.3: [Configuration read/write handling with safe fallback defaults]
- **Verification**: [Command or automated check to verify Phase 1 in isolation]

### Phase 2: WebGUI / CLI / Interface Integration
- [ ] Task 2.1: [Add UI controls or CLI flags matching existing design idioms]
- [ ] Task 2.2: [Client-side / server-side input validation and error feedback]
- [ ] Task 2.3: [Status reporting or log output formatting]
- **Verification**: [Inspection or UI check to verify interface integration]

### Phase 3: Automated Testing, Bug & Regression Prevention
- [ ] Task 3.1: [Write reproduction/regression tests for any bugs or potential regressions identified]
- [ ] Task 3.2: [Implement new unit / t/*.t / testlab / WebGUI tests covering core functionality]
- [ ] Task 3.3: [Test edge cases: missing dependencies, invalid input, timeouts, or failure recovery]
- **Verification**: [Execute the test suite, e.g. `prove -v t/...`, testlab runner, or DevTools MCP run]

### Phase 4: Documentation & Release Packaging
- [ ] Task 4.1: [Update user guide / documentation]
- [ ] Task 4.2: [Update change log / release notes]
- **Verification**: [Documentation review and lint check]

---

## 4. Safety, Security & Guardrail Engineering

> [!CAUTION]
> **Safety & Security Are Top Priority**: This application operates with root/system privileges, manages persistent filesystem datasets, and orchestrates remote SSH communications. Any proposed changes must strictly safeguard data integrity, enforce least privilege, and prevent command injection.

### 4.1 Threat Modeling & Security Controls
*   **Input Validation & Sanitization**: [Specify exact regex, whitelisting, or schema validation for dataset names, SSH hosts/ports, paths, and options. Untrusted input must never be directly interpolated into shell strings.]
*   **Command Execution Safety**: [Specify how subcommands are invoked safely (e.g., passing argument arrays, escaping via `escapeshellarg`, strict parameter parsing, avoiding `system("$var")`).]
*   **Privilege & Boundary Discipline**: [Enforce least privilege; maintain restrictive file permissions (e.g., `0600` for private SSH keys); preserve restricted SSH command scopes (e.g., `restrict_zfs` policy).]
*   **Secrets & Credential Protection**: [Ensure no private keys, passwords, or tokens are leaked into logs, WebGUI DOM attributes, or world-readable files.]

### 4.2 Data Safety & Guardrails
*   **Destructive Operation Safeguards**: [What prevents accidental dataset destruction or data loss? Enforce explicit validation, double-confirmation, and guard against unintended recursive `zfs destroy` or sync overwrites.]
*   **Fail-Safe Defaults & Atomic Operations**: [Ensure that if replication fails, network drops, or disk is full, the system fails safely (aborts cleanly) without corrupting existing configuration or leaving dangling broken states.]

---

## 5. Edge Cases, Error Handling & Recovery

| Edge Case / Failure Mode | Expected Behavior | Handling / Fallback Mechanism |
| :--- | :--- | :--- |
| **Invalid or Malformed Input** | Fail safely with clear user error | Validate before persistence; reject gracefully |
| **External Dependency Missing** | Prevent operation and warn user | Early check with informative error message |
| **Timeout or Subprocess Failure** | Clean up partial state | Safe exit, log diagnostic details, notify user |
| **Legacy / Unset Configuration** | Default to existing baseline behavior | Seamless backward compatibility |

---

## 6. Automated Verification & Regression Test Plan

> [!IMPORTANT]
> **Bug & Regression Prevention Mandate**: Whenever modifying existing code, resolving a reported defect, or altering system behavior, the implementation plan **must** specify automated tests for each bug or regression risk identified. Tests must be created in whatever test harness best fits the issue (e.g. Unit tests, `t/*.t` TAP tests, testlab scripts, or browser DevTools tests) so we permanently reduce the chance of introducing new issues or repeating past failures.

### 6.1 Test Modalities & Placement
Select the test modality that best fits the bug, regression risk, or new capability:

| Test Modality | Scope / Best For | Target Location / Command |
| :--- | :--- | :--- |
| **TAP Tests (`t/*.t`)** | CLI wrappers, argument parsing, config handling, hooks | `t/[name].t` via `prove -v t/[name].t` |
| **Unit / Syntax Tests** | Pure logic, PHP functions, syntax validation | `t/php_syntax_and_eval.t` or dedicated unit test |
| **Testlab System Tests** | WSL/QEMU multi-node integration, ZFS datasets, SSH keys | `testlab/scripts/...` via PowerShell |
| **WebGUI Navigation Tests** | Browser forms, DOM states, button clicks, error banners | Chrome DevTools MCP via `testlab-web-navigation` skill |
| **Custom / Diagnostic Scripts** | Edge cases, race condition simulation, mock services | `t/` or testlab helper scripts |

### 6.2 Regression Test Cases & Bug Assertions
Enumerate the specific regression cases to be locked in with tests:

*   **Regression Case 1 ([Bug/Failure Description])**:
    *   *Test Harness*: [`t/*.t` / Unit / Testlab / Web Navigation]
    *   *Test File / Script*: `[path/to/test]`
    *   *Input / Trigger Condition*: `[Reproduction steps or faulty input]`
    *   *Pass Assertion*: `[Exact expected assertion verifying the bug does not recur]`
*   **Regression Case 2 ([Edge Case / Interaction Risk])**:
    *   *Test Harness*: [`t/*.t` / Unit / Testlab / Web Navigation]
    *   *Test File / Script*: `[path/to/test]`
    *   *Pass Assertion*: `[Assertion verifying existing functionality is preserved]`

---

## 7. Maintainer Manual Testing Walkthrough

> [!NOTE]
> If the feature is manually testable (via WebGUI, CLI, config edits, or testlab instances), this section provides a step-by-step runbook for the maintainer to verify the changes personally. If the feature is strictly internal/programmatic with no manual test path, explicitly state why below and provide diagnostic commands to verify state.

### 7.1 Test Environment & Prerequisites
*   **Target Environment**: [e.g. Local testlab nodeA (`http://127.0.0.1:8080`), local dev host, or specific VM]
*   **Initial Setup & Preconditions**: [e.g. Test ZFS pool/dataset created, specific plugin setting enabled, mock remote host online]
*   **Required Tools / Context**: [e.g. Root shell access, active Unraid WebGUI admin session, browser developer tools]

### 7.2 Step-by-Step Test Procedure (Happy Path)
1.  **Preparation**:
    *   Command / Action: `[Command to set up state or verify clean starting baseline]`
2.  **Trigger Action (WebGUI or CLI)**:
    *   *If WebGUI*: Navigate to **[Page / Tab]** > Click **[Control / Button]** > Enter **[Sample Values]** > Click **[Apply / Save]**.
    *   *If CLI*: Run `[Exact command line with sample arguments]`.
3.  **Expected Visible Behavior**:
    *   [Exact UI visual changes, success notifications, banners, or stdout messages to look for]
4.  **Verification & State Inspection**:
    *   Config File: Verify contents of `[path/to/config]` with `cat [path/to/config]`
    *   Log Output: Inspect log entries via `tail -n 20 /var/log/syslog` or `[path/to/logfile]`
    *   System State: Verify underlying state (e.g. `zfs list -t snapshot`, cron schedule via `crontab -l`)

### 7.3 Negative & Edge Case Manual Tests
1.  **Invalid Input Handling**:
    *   Action: [Supply empty string, special characters, or nonexistent path]
    *   Expected Behavior: [Inline UI warning displayed; no crashes or corrupted config files]
2.  **Degraded / Offline State**:
    *   Action: [Simulate unreachable peer, stopped daemon, or missing dependency]
    *   Expected Behavior: [Graceful error toast or informative message; safe fallback behavior]

### 7.4 Environment Cleanup & Teardown
*   **Reset Steps**: [Exact commands or WebGUI actions to revert the test environment back to a clean baseline state]
    *   `[e.g. zfs destroy testpool/sample_dataset]`
    *   `[e.g. Revert config setting back to default]`

*(If Not Manually Testable: Explain technical reason why manual testing is impractical/impossible, and provide the diagnostic queries or assertions to run instead).*

---

## 8. Risk Assessment & Rollback Strategy

*   **Risk Level**: Low / Medium / High
*   **Potential Regressions**: [What existing workflows touch this area?]
*   **Rollback Mechanism**: [How to revert if an issue arises post-deployment]

---

## 9. Handoff Checklist for Implementing Agent
- [ ] Have all target files and line ranges been confirmed via codebase search?
- [ ] Are all project architectural constraints (e.g. `AGENTS.md`) adhered to?
- [ ] **Safety & Security First**: Are input sanitization, injection safeguards, least privilege, and data loss protections explicitly engineered?
- [ ] Are acceptance criteria clearly defined for every task?
- [ ] Can verification steps be executed without human intervention where possible?
- [ ] Does the plan provide a complete manual testing walkthrough for the maintainer (or explicit justification if not applicable)?
- [ ] Are automated regression tests mandated (unit, t/, testlab, or web navigation) for all identified bugs and regression risks?



