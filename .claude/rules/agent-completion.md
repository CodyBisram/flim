# Agent Completion Contract

Use this compact handoff format unless the agent defines an additional domain-specific field.
Do not paste full build logs when a concise result is sufficient. Include failure excerpts only
when they are needed to diagnose or reproduce the problem.

```text
STATUS: COMPLETE | BLOCKED | NEEDS OWNER ACTION

CHANGED:
- path: concise reason

VERIFIED:
- exact command or check: PASS | FAIL | NOT RUN

NOT VERIFIED:
- item: reason

RISKS:
- concrete remaining risk, or NONE

HANDOFF:
- next agent and exact task, or NONE
```

Rules:
- Evidence must describe the current working tree or exact revision being handed off.
- Do not claim verification from an earlier revision after files changed.
- Report only concrete risks. Do not invent generic cautions.
- A blocked agent should stop rather than broaden its own scope.
