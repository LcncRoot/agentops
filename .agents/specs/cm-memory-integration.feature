Feature: CM-backed startup and closeout artifacts
  AgentOps should preserve CM outputs under Ariston-owned .agents paths
  without breaking existing lifecycle flows when CM is unavailable.

  Scenario: Codex startup captures CM context into repo-local artifacts
    Given a repo-local .agents workspace exists
    And a cm executable is available on PATH
    When ao codex start runs with a task query
    Then the raw CM context is written to .agents/ao/context/cm-context.json
    And an operator-facing summary is written to .agents/briefings/cm-context.md
    And the startup lifecycle still succeeds

  Scenario: Codex closeout stages CM reflection suggestions
    Given a repo-local .agents workspace exists
    And a cm executable is available on PATH
    And a transcript path is available for closeout
    When ao codex stop runs
    Then the raw CM reflection is written under .agents/ao/provenance/cm
    And one or more pending knowledge candidates are staged under .agents/knowledge/pending
    And the closeout lifecycle still succeeds

  Scenario: Missing CM fails open
    Given no cm executable is available on PATH
    When ao codex start or ao codex stop runs
    Then the lifecycle command still succeeds
    And no CM-specific error is surfaced to the operator
