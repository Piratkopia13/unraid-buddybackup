# Feature Viability & Scope Evaluation Rubric

This reference provides a rigorous evaluation framework to investigate feature requests before any implementation begins. Use this rubric during **Phase 1 (Viability & Investigation)** to determine whether a feature should be built, reshaped, or rejected.

---

## The Four Core Pillars of Investigation

### Pillar 1: Root Use Case Validation (The "Why")
Separate the user's *proposed solution* from their *underlying problem*.

*   **Problem Identification**: What concrete limitation, pain point, or friction is the user experiencing?
*   **Workflow Context**: In what real-world scenario does this problem arise? Is it a common workflow or a niche edge case?
*   **Symptom vs. Root Cause**: Is the user asking for a feature to work around an existing defect, confusing UI, or unstated prerequisite?
*   **Frequency & Impact**: How often does this issue occur, and how critical is its impact on user productivity, safety, or system reliability?

---

### Pillar 2: Duplication & Existing Mechanism Audit
Avoid creating duplicate ways to accomplish the same task in the application.

*   **Existing Capabilities**: Does the app already possess a mechanism, setting, hook, or CLI option that achieves this outcome (even if configured differently)?
*   **Partial Overlap**: Does the requested feature overlap with an existing feature? If so, would adding it create confusing ambiguity ("Which option should I use?")?
*   **Single Source of Truth**: Would this introduce a competing configuration store, parallel state, or divergent code path?
*   **Enhancement vs. Duplication**: Can an existing feature be slightly broadened or clarified instead of adding a brand-new feature or setting?

---

### Pillar 3: Architectural & Design Fit (Alternative Solutions)
Evaluate how the feature aligns with the system's design idioms, architecture, and technology boundaries.

*   **Native vs. Bolted-On**: Does the requested implementation feel like a natural evolution of the app, or does it feel "bolted on" as an awkward outlier?
*   **Superior Architectural Alternative**: Is there a simpler, more robust, or more idiomatic solution that fits the app's existing architecture better than what the user proposed?
    *   *Example*: Instead of adding a custom background cron manager, leverage existing system hooks or scheduler wrappers.
    *   *Example*: Instead of adding a new database/state file, leverage existing configuration parsers.
*   **Boundary & Policy Compliance**:
    *   Does it respect vendor separation policies (e.g., zero edits to upstream vendor dependencies; using dedicated plugin wrappers instead)?
    *   Does it maintain modularity, encapsulation, and clean API boundaries?
    *   Does it introduce tight coupling between previously independent layers (e.g., UI directly executing low-level shell without going through control scripts)?

---

### Pillar 4: Scope Boundary & Feature Creep Filter
Protect the application's core identity, mission, and maintainability.

*   **Core Purpose Alignment**: Is this feature strictly within the app's primary domain, or is it wandering into another tool's domain?
    *   *Example*: In a backup plugin, managing ZFS replication is core; managing container orchestration or general disk partitioning is feature creep.
*   **Platform & OS Responsibility**: Does this request belong in the application, or should it be handled by the underlying operating system, base platform, or dedicated third-party tools?
*   **Maintenance & Cognitive Tax**: Does the long-term cost of testing, documenting, maintaining, and supporting this feature outweigh the benefit for the user base?
*   **Target Audience Fit**: Does this benefit a meaningful portion of users, or does it add cognitive noise and complexity for 99% of users to satisfy an ultra-specialized 1%?

---

### Pillar 5: Safety & Security Evaluation (Top Priority)
Safety and security are non-negotiable prerequisites. Convenience or feature richness must never compromise data integrity, privilege boundaries, or secure execution.

*   **Data Safety & Destruction Risks**:
    *   Could this feature cause data loss, accidental overwriting, or unintended dataset destruction (e.g., recursive `zfs destroy`, misconfigured sync targets)?
    *   Are destructive operations protected by strict confirmation, validation, and fail-safe guards?
*   **Injection & Shell Security**:
    *   Does the feature accept user-supplied input (dataset names, IP addresses, paths, cron schedules, SSH options) that passes into shell commands or background scripts?
    *   Is all user input strictly sanitized, validated, and escaped? Are commands constructed using safe argument arrays rather than raw string interpolation?
*   **Privilege & Boundary Discipline**:
    *   Does the feature require elevated/root permissions? Can it be restricted to minimal necessary scope?
    *   Does it maintain secure SSH key permissions (`0600`) and enforce restricted command policies (e.g., `restrict_zfs` wrappers) rather than granting blanket shell access?
*   **Fail-Safe Defaults & Defensive Handling**:
    *   If a subprocess fails, network drops, or input is malformed, does the system fail safely (abort/halt) without corrupting existing configurations or leaving datasets in half-replicated states?

---

## Decision Matrix & Heuristics

| Signal | Evaluation Result | Recommended Action |
| :--- | :--- | :--- |
| **Presents unmitigated safety or security hazard** | **Immediate No-Go** (Hazard) | Reject immediately; explain security/data integrity risk and why it cannot be built. |
| **Existing mechanism already solves the use case** | No-Go (Duplication) | Close request; document how to use the existing feature; optionally plan UX/doc clarification. |
| **Out-of-scope / Operating system responsibility** | No-Go (Feature Creep) | Close request; explain platform boundaries and point to appropriate external tools or OS settings. |
| **Violates architectural boundaries or vendor policy** | Pivot or No-Go | If problem is valid, pivot to an architecturally compliant alternative; if impossible without violating boundaries, reject. |
| **Maintenance tax far exceeds user benefit** | No-Go (High Burden) | Close request with technical cost/benefit analysis. |
| **Valid problem, but proposed mechanism has security flaws** | Pivot (Redesign) | Accept use case; redesign with strict sanitization, least privilege, and safety guardrails. |
| **Valid problem, aligned with mission, safe & clean architectural fit** | Go (Approved) | Proceed immediately to Phase 3 (Handoff-Ready Implementation Plan). |

---

## Triage: Feature Request vs. Bug Report

Before evaluating viability, ensure the request is actually a feature proposal:

*   **Bug Report / Regression**: The application already claims or is intended to support the behavior, but it produces an error, crash, incorrect result, or regression.
    *   *Action*: Stop feature planning. Hand off to the debugging and defect resolution workflow.
    *   *Regression Prevention Mandate*: For any bug or regression, an automated reproduction/regression test must be authored before or alongside the fix to ensure the defect cannot recur. Choose the test harness that best matches the issue (e.g. Unit tests, Perl `t/*.t` TAP tests, `testlab` QEMU scripts, or browser DevTools tests via `testlab-web-navigation`).
*   **Feature Request**: The application functions as designed, but the user is requesting new behavior, extended capabilities, added configuration options, or alternative workflows.
    *   *Action*: Proceed with this viability evaluation. (If the feature touches fragile areas or fixes adjacent bugs, mandate regression test coverage in the implementation plan).

