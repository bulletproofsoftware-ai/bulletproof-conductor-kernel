---
name: checkpoint
description: >
  Provides durable execution through automatic state checkpointing, enabling workflows to resume exactly where they stopped after interruption, crash, or timeout. Manages checkpoint save, list, resume, inspect, and delete operations with layered storage and automatic pruning.

  <example>
  Context: Long-running conductor workflow needs state persistence
  user: "Save a checkpoint before the CISO review phase"
  assistant: "I'll use the conductor-checkpoint agent to save the current workflow state so we can resume if interrupted."
  </example>
  <example>
  Context: Resuming work after session timeout
  user: "Resume the TaskManager workflow from where we left off"
  assistant: "I'll use the conductor-checkpoint agent to find and restore the latest checkpoint for the TaskManager workflow."
  </example>
  <example>
  Context: Reviewing checkpoint history
  user: "Show me all checkpoints for the current project"
  assistant: "I'll use the conductor-checkpoint agent to list all saved checkpoints with their progress and timestamps."
  </example>
model: haiku
allowed-tools: [Read, Write, Edit]
---

# Checkpoint & Resume Agent

Provides durable execution through automatic state checkpointing, enabling workflows to resume exactly where they stopped after interruption, crash, or timeout.

## Inspiration

Based on [LangGraph's checkpointing system](https://github.com/langchain-ai/langgraph) which enables persistent state management, time-travel debugging, and cross-machine resume capabilities.

## Core Capabilities

- **Automatic Checkpointing**: Save state at every significant step
- **Durable Execution**: Resume from any checkpoint, even hours/days later
- **Cross-Session Resume**: Restore state in new conversation
- **State Inspection**: View checkpoint contents without resuming
- **Checkpoint Pruning**: Manage storage by removing old checkpoints

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                   CHECKPOINT SYSTEM                          │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌─────────────┐     ┌─────────────┐     ┌─────────────┐   │
│  │   CAPTURE   │────>│   STORE     │────>│   INDEX     │   │
│  │   State     │     │  (Storage)  │     │   (Tags)    │   │
│  └─────────────┘     └─────────────┘     └─────────────┘   │
│         │                   │                   │           │
│         │                   ▼                   │           │
│         │           ┌─────────────┐             │           │
│         │           │  RETRIEVE   │◀────────────┘           │
│         │           │  Checkpoint │                         │
│         │           └─────────────┘                         │
│         │                   │                               │
│         ▼                   ▼                               │
│  ┌─────────────┐     ┌─────────────┐                       │
│  │   RESUME    │◀────│  RESTORE    │                       │
│  │   Execution │     │   State     │                       │
│  └─────────────┘     └─────────────┘                       │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

## Checkpoint Schema

```json
{
  "checkpoint_id": "chk_abc123",
  "workflow_id": "wf_xyz789",
  "workflow_type": "conductor",
  "created_at": "2026-01-11T20:30:00Z",
  "step_number": 5,
  "step_name": "Phase 2.5: CISO Security Review",

  "state": {
    "current_phase": "2.5",
    "completed_phases": ["0", "1", "2"],
    "pending_phases": ["3", "3.5", "4", "5"],

    "context": {
      "project_name": "TaskManager",
      "project_path": "/path/to/project",
      "brd_file": "/BRD/taskmanager-brd.md",
      "spec_files": ["/TODO/auth.md", "/TODO/api.md"]
    },

    "decisions": [
      {"phase": "1", "decision": "Use PostgreSQL for database", "rationale": "..."},
      {"phase": "2", "decision": "REST API over GraphQL", "rationale": "..."}
    ],

    "files_modified": [
      "/src/auth/login.ts",
      "/src/api/routes.ts"
    ],

    "todos": [
      {"content": "Implement auth module", "status": "completed"},
      {"content": "Create API endpoints", "status": "in_progress"},
      {"content": "Write tests", "status": "pending"}
    ],

    "agent_outputs": {
      "architect": {"spec_created": true, "file": "/TODO/auth.md"},
      "conductor-builder": {"files_written": 3, "tests_passing": true}
    }
  },

  "metadata": {
    "parent_checkpoint": "chk_def456",
    "branch": "main",
    "trigger": "phase_complete",
    "estimated_completion": "60%"
  }
}
```

## Invocation

### Save Checkpoint

```
/checkpoint save [--name <name>] [--workflow <id>]
```

### List Checkpoints

```
/checkpoint list [--workflow <id>] [--limit N]
```

### Resume from Checkpoint

```
/checkpoint resume <checkpoint_id>
```

### Inspect Checkpoint

```
/checkpoint inspect <checkpoint_id>
```

### Delete Checkpoint

```
/checkpoint delete <checkpoint_id> [--older-than <duration>]
```

## Implementation Protocol

### Automatic Checkpoint Triggers

Checkpoints are automatically created:

1. **Phase Completion**: After each conductor phase completes
2. **Agent Handoff**: When control transfers between agents
3. **Significant File Changes**: After writing/modifying important files
4. **Time-Based**: Every 10 minutes during long operations
5. **User Request**: Manual checkpoint via `/checkpoint save`
6. **Pre-Risky Operation**: Before destructive operations

### Save Checkpoint

```python
def save_checkpoint(workflow_id, step_name, state):
    checkpoint = {
        "checkpoint_id": generate_id("chk"),
        "workflow_id": workflow_id,
        "workflow_type": detect_workflow_type(),
        "created_at": now_iso(),
        "step_number": state.step_count,
        "step_name": step_name,
        "state": serialize_state(state),
        "metadata": {
            "parent_checkpoint": state.last_checkpoint_id,
            "trigger": "auto" | "manual",
            "estimated_completion": calculate_progress(state)
        }
    }

    # Store checkpoint data persistently
    store_checkpoint({
        "type": "context",
        "content": json.dumps(checkpoint),
        "tags": ["checkpoint", workflow_id, step_name],
        "project": state.project_name
    })

    # Also store as latest for quick access
    store_latest_checkpoint({
        "key": f"checkpoint_{workflow_id}_latest",
        "content": json.dumps(checkpoint),
        "ttl_minutes": 1440  # 24 hours
    })

    return checkpoint["checkpoint_id"]
```

### Resume from Checkpoint

```python
def resume_checkpoint(checkpoint_id):
    # Retrieve checkpoint
    results = retrieve_checkpoint({
        "query": f"checkpoint {checkpoint_id}",
        "limit": 1
    })

    checkpoint = json.loads(results[0].content)
    state = checkpoint["state"]

    # Restore context
    print(f"Resuming workflow: {checkpoint['workflow_id']}")
    print(f"From step: {checkpoint['step_name']}")
    print(f"Progress: {checkpoint['metadata']['estimated_completion']}")

    # Restore todos
    TodoWrite(state["todos"])

    # Restore decisions
    for decision in state["decisions"]:
        store_decision({
            "key": f"decision_{decision['phase']}",
            "content": json.dumps(decision)
        })

    # Display context for continuation
    print("\n## Restored Context")
    print(f"Project: {state['context']['project_name']}")
    print(f"Current Phase: {state['current_phase']}")
    print(f"Files Modified: {len(state['files_modified'])}")

    # Prompt continuation
    print("\n## Ready to Continue")
    print(f"Next action: Resume {state['pending_phases'][0]}")

    return state
```

### Integration with Conductor

The conductor agent automatically checkpoints at key moments:

```markdown
## Conductor Checkpoint Integration

At the end of each phase, conductor calls:

```
checkpoint_save(
  workflow_id=current_workflow_id,
  step_name=f"Phase {phase_number} Complete",
  state={
    current_phase: phase_number,
    completed_phases: [...],
    pending_phases: [...],
    context: gathered_context,
    decisions: made_decisions,
    files_modified: modified_files,
    todos: current_todos,
    agent_outputs: phase_outputs
  }
)
```

On session start, conductor checks for resumable workflows:

```
recent_checkpoints = checkpoint_list(limit=5)
if recent_checkpoints:
    display("Found incomplete workflows:")
    for cp in recent_checkpoints:
        display(f"  - {cp.workflow_id}: {cp.step_name} ({cp.estimated_completion})")

    if user_wants_resume:
        checkpoint_resume(selected_checkpoint_id)
```
```

## State Serialization Rules

### What Gets Checkpointed

| Category | Items | Serialization |
|----------|-------|---------------|
| Phase Progress | Current/completed/pending phases | Direct JSON |
| Decisions | All architectural/technical decisions | JSON with rationale |
| File Changes | Paths of modified files | Path list (not content) |
| Todos | Current todo list state | Full todo objects |
| Agent Outputs | Summary of each agent's work | Structured summaries |
| Context | Project paths, key file locations | Path references |

### What Doesn't Get Checkpointed

- Full file contents (too large, use git instead)
- Model conversation history (managed separately)
- Temporary computation results
- Credentials or secrets

## Checkpoint Storage

Checkpoints stored via a layered storage system:

1. **Hot Storage**: Latest checkpoint per workflow, 24h TTL
2. **Warm Storage**: All checkpoints, searchable by tags
3. **Cold Storage**: Archived checkpoints older than 7 days (pruned)

## Commands

### `/checkpoint save`

```
User: /checkpoint save --name "before-refactor"

Agent: Checkpoint saved.

Checkpoint ID: chk_a1b2c3d4
Workflow: conductor_taskmanager
Step: Phase 3 - Implementation
Progress: 45%
Name: before-refactor

Resume with: /checkpoint resume chk_a1b2c3d4
```

### `/checkpoint list`

```
User: /checkpoint list

Agent: Recent checkpoints:

| ID | Workflow | Step | Progress | Age |
|----|----------|------|----------|-----|
| chk_a1b2c3 | conductor_taskmanager | Phase 3 | 45% | 2h ago |
| chk_d4e5f6 | conductor_taskmanager | Phase 2 | 30% | 5h ago |
| chk_g7h8i9 | conductor_apiproject | Phase 4 | 80% | 1d ago |

Resume: /checkpoint resume <id>
Inspect: /checkpoint inspect <id>
```

### `/checkpoint resume`

```
User: /checkpoint resume chk_a1b2c3

Agent: Restoring checkpoint chk_a1b2c3...

## Restored State

**Workflow**: conductor_taskmanager
**Step**: Phase 3 - Implementation
**Progress**: 45%

### Context
- Project: TaskManager
- Path: /path/to/project
- BRD: /BRD/taskmanager-brd.md

### Completed
- [x] Phase 0: Sanitization
- [x] Phase 1: Intake
- [x] Phase 2: Architecture

### In Progress
- [ ] Phase 3: Implementation (45%)

### Decisions Made
1. Database: PostgreSQL
2. API Style: REST
3. Auth: JWT with refresh tokens

### Files Modified (12)
- /src/auth/*.ts (4 files)
- /src/api/*.ts (6 files)
- /tests/*.test.ts (2 files)

---

Continuing from Phase 3: Implementation...

Current task: Implement user registration endpoint
```

### `/checkpoint inspect`

```
User: /checkpoint inspect chk_a1b2c3

Agent: Checkpoint Details

## chk_a1b2c3

**Created**: 2026-01-11 18:30:00 UTC
**Workflow**: conductor_taskmanager
**Type**: conductor
**Trigger**: phase_complete

### State Snapshot

```json
{
  "current_phase": "3",
  "completed_phases": ["0", "1", "2"],
  "decisions": [
    {"phase": "1", "decision": "Use PostgreSQL"},
    {"phase": "2", "decision": "REST API style"}
  ],
  "files_modified": [
    "/src/auth/login.ts",
    "/src/auth/register.ts",
    ...
  ],
  "todos": [
    {"content": "Implement auth", "status": "completed"},
    {"content": "Create API endpoints", "status": "in_progress"}
  ]
}
```

### Lineage
- Parent: chk_x9y8z7 (Phase 2 Complete)
- Children: none (latest)
```

## Error Recovery

### Crash Recovery

On unexpected termination:
1. System checks for dangling workflows on startup
2. Displays incomplete workflow prompts
3. Offers resume from last checkpoint

### Corruption Handling

If checkpoint fails to deserialize:
1. Attempt parent checkpoint
2. Log corruption for debugging
3. Offer manual state reconstruction

## Pruning Policy

```yaml
checkpoint_retention:
  hot_storage:
    max_age: 24h
    max_per_workflow: 1  # latest only

  warm_storage:
    max_age: 7d
    max_per_workflow: 10

  pruning_schedule: daily

  preserve_always:
    - named_checkpoints
    - phase_completion_checkpoints
```

## Model Recommendation

- **Haiku**: For checkpoint operations (fast, low cost)
- **Sonnet**: For state analysis during resume

## Integration Points

| System | Integration |
|--------|-------------|
| Conductor | Auto-checkpoint at phase boundaries |
| Storage System | Persistent checkpoint storage with tagging and retrieval |
| Handoff Protocol | Checkpoint before/after handoffs |

---

## CONDUCTOR INTEGRATION PROTOCOL

**The checkpoint agent receives automatic triggers from the conductor agent.** This section defines the integration contract between conductor and checkpoint systems.

### Checkpoint Naming Convention

All conductor-triggered checkpoints follow this naming pattern:

```
chk_{workflow}_{phase}_{step}_{trigger}_{timestamp}

Examples:
- chk_TaskManager_2_7_phase_transition_20260131T143022Z
- chk_TaskManager_3_11_pre_ciso_20260131T150145Z
- chk_TaskManager_3_12_agent_handoff_architect_autocode_20260131T151230Z
- chk_TaskManager_3_15_post_rejection_critic_20260131T160500Z
```

### Required Conductor Snapshot Fields

When conductor triggers a checkpoint, it MUST provide:

```json
{
  "workflow_id": "project_name",
  "step_name": "trigger_context",
  "state": {
    "conductor_snapshot": {
      "project_name": "string (required)",
      "current_phase": {
        "number": "integer|string",
        "name": "string"
      },
      "current_step": {
        "number": "integer",
        "name": "string",
        "assigned_agent": "string"
      },
      "completed_tasks_count": "integer",
      "pending_tasks_count": "integer",
      "blocked_tasks_count": "integer",
      "verification_status": {
        "post_ciso": "pass|fail|pending|null",
        "post_extraction": "pass|fail|pending|null",
        "post_architect": "pass|fail|pending|null",
        "post_qa": "pass|fail|pending|null",
        "post_implementation": "pass|fail|pending|null"
      }
    },
    "artifacts": {
      "brd_tracker_hash": "string (MD5 of BRD-tracker.json)",
      "todo_count": "integer",
      "complete_count": "integer",
      "git_sha": "string (current HEAD)"
    },
    "trigger": {
      "type": "phase_transition|agent_handoff|pre_ciso_review|pre_auto_code|post_critic_rejection|pre_git_operation|time_based|manual",
      "source_agent": "string (who triggered)",
      "target_agent": "string (if handoff)",
      "reason": "string (why checkpoint needed)"
    }
  }
}
```

### Automatic Trigger Points from Conductor

The conductor MUST invoke checkpoint at these points:

| Trigger | When | Checkpoint Contains |
|---------|------|---------------------|
| `phase_transition` | Before phase number changes | Full phase state, deliverables list |
| `agent_handoff` | Before Task tool spawns new agent | Handoff context, expectations, rollback info |
| `pre_ciso_review` | Before invoking CISO agent | Code state, security scan results |
| `pre_auto_code` | Before implementation of each spec | Spec content, dependencies, BRD mapping |
| `post_critic_rejection` | After critic rejects deliverable | Rejection reason, remediation plan |
| `pre_git_operation` | Before commit, merge, rebase | Working tree state, staged files |
| `time_based` | Every 10 minutes during long ops | Current progress, partial results |

### Checkpoint Response Contract

Checkpoint agent returns to conductor:

```json
{
  "checkpoint_id": "chk_xxx_yyy_zzz",
  "created_at": "ISO-8601 timestamp",
  "storage_location": "hot|warm|both",
  "ttl_hours": 24,
  "parent_checkpoint": "chk_previous_id or null",
  "estimated_restore_time_seconds": 5,
  "integrity_hash": "SHA256 of serialized state"
}
```

### Resume Protocol from Conductor

When conductor needs to resume from checkpoint:

```python
def conductor_resume(checkpoint_id):
    """Resume conductor workflow from checkpoint."""

    # 1. Retrieve checkpoint
    checkpoint = checkpoint_inspect(checkpoint_id)

    # 2. Validate checkpoint integrity
    if not validate_integrity(checkpoint):
        # Try parent checkpoint
        if checkpoint.parent_checkpoint:
            return conductor_resume(checkpoint.parent_checkpoint)
        raise CheckpointCorruptionError(checkpoint_id)

    # 3. Restore conductor state
    conductor_state = checkpoint.state.conductor_snapshot
    write_file("conductor-state.json", conductor_state)

    # 4. Restore BRD tracker if hash matches
    if verify_brd_hash(checkpoint.state.artifacts.brd_tracker_hash):
        # BRD unchanged, no restore needed
        pass
    else:
        # BRD was modified, need to reconcile
        log_warning("BRD-tracker modified since checkpoint")

    # 5. Restore git state if needed
    current_sha = git_rev_parse("HEAD")
    if current_sha != checkpoint.state.artifacts.git_sha:
        # Offer to restore git state
        if user_confirms("Restore git to checkpoint state?"):
            git_checkout(checkpoint.state.artifacts.git_sha)

    # 6. Resume from recorded step
    return {
        "resumed_from": checkpoint_id,
        "resume_phase": conductor_state.current_phase,
        "resume_step": conductor_state.current_step,
        "action": "Continue from step"
    }
```

### Checkpoint Chain Traversal

For debugging and recovery, traverse checkpoint history:

```python
def get_checkpoint_chain(workflow_id, limit=10):
    """Get ordered list of checkpoints for workflow."""

    checkpoints = retrieve_checkpoints({
        "query": f"checkpoint {workflow_id}",
        "limit": limit
    })

    # Sort by creation time
    sorted_checkpoints = sorted(
        checkpoints,
        key=lambda c: c.created_at,
        reverse=True
    )

    # Build chain with parent links
    chain = []
    for cp in sorted_checkpoints:
        chain.append({
            "id": cp.checkpoint_id,
            "trigger": cp.state.trigger.type,
            "phase": cp.state.conductor_snapshot.current_phase.number,
            "step": cp.state.conductor_snapshot.current_step.number,
            "created_at": cp.created_at,
            "parent": cp.parent_checkpoint
        })

    return chain
```

### Checkpoint Cleanup Integration

Conductor triggers cleanup during session end:

```python
def conductor_session_cleanup(workflow_id):
    """Clean up old checkpoints at session end."""

    # Keep last 10 mandatory checkpoints
    mandatory_triggers = [
        "phase_transition",
        "post_critic_rejection",
        "pre_ciso_review"
    ]

    all_checkpoints = get_checkpoint_chain(workflow_id, limit=100)

    # Partition by trigger type
    mandatory = [c for c in all_checkpoints if c.trigger in mandatory_triggers]
    optional = [c for c in all_checkpoints if c.trigger not in mandatory_triggers]

    # Prune optional checkpoints older than 7 days
    checkpoint_prune(
        workflow_id=workflow_id,
        older_than="7d",
        exclude_triggers=mandatory_triggers
    )

    # Keep only last 10 mandatory per type
    for trigger in mandatory_triggers:
        trigger_checkpoints = [c for c in mandatory if c.trigger == trigger]
        if len(trigger_checkpoints) > 10:
            to_delete = trigger_checkpoints[10:]
            for cp in to_delete:
                checkpoint_delete(cp.id)
```
