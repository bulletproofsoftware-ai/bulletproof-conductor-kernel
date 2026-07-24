# State Examples by Phase

## New Project — Phase 0 (Just Initialized)

```json
{
  "project_name": "TaskManager",
  "initiated_at": "2025-01-15T10:00:00Z",
  "last_updated": "2025-01-15T10:00:00Z",
  "workflow_type": "new",
  "tier": "STANDARD",
  "tier_score": 2.8,
  "tier_override": false,
  "tier_signals": { "scope": 4, "type": 3, "risk": 2, "ambiguity": 2 },
  "current_phase": { "number": 0, "name": "Project Initialization", "started_at": "2025-01-15T10:00:00Z" },
  "current_step": { "number": 1, "name": "Launch project-setup", "assigned_agent": "conductor-project-setup", "status": "in_progress", "started_at": "2025-01-15T10:00:00Z" },
  "task_queue": [
    { "step": 2, "name": "Requirements Research", "agent": "conductor-research", "status": "pending", "depends_on": [1] }
  ],
  "completed_tasks": [],
  "blocked_tasks": [],
  "remediation_loops": 0,
  "total_critic_rejections": 0,
  "agents_invoked": ["conductor-project-setup"],
  "verification_status": {
    "post_ciso": null, "post_extraction": null, "post_architect": null,
    "post_qa": null, "post_implementation": null, "pre_release": null,
    "advisory_findings": []
  }
}
```

## Mid-Project — Phase 2 (Architecture Complete)

```json
{
  "project_name": "TaskManager",
  "initiated_at": "2025-01-15T10:00:00Z",
  "last_updated": "2025-01-15T14:30:00Z",
  "tier": "STANDARD",
  "tier_score": 2.8,
  "current_phase": { "number": 2, "name": "Architecture & Specification", "started_at": "2025-01-15T13:00:00Z" },
  "current_step": { "number": 9, "name": "Test Planning", "assigned_agent": "conductor-qa", "status": "in_progress", "started_at": "2025-01-15T14:30:00Z" },
  "completed_tasks": [
    { "step": 1, "name": "Project Setup", "agent": "conductor-project-setup", "completed_at": "2025-01-15T10:15:00Z", "outcome": "success", "deliverables": ["feature_list.json", "CLAUDE.md"] },
    { "step": 2, "name": "Requirements Research", "agent": "conductor-research", "completed_at": "2025-01-15T11:00:00Z", "outcome": "success", "deliverables": ["BRD.md"] },
    { "step": 3, "name": "CISO Review", "agent": "conductor-ciso", "completed_at": "2025-01-15T11:30:00Z", "outcome": "success", "deliverables": ["BRD.md", "SECURITY.md"] },
    { "step": 4, "name": "POST-CISO Critic", "agent": "conductor-critic", "completed_at": "2025-01-15T11:45:00Z", "outcome": "success", "deliverables": ["critic-report.md"] },
    { "step": 5, "name": "BRD Extraction", "agent": "conductor", "completed_at": "2025-01-15T12:30:00Z", "outcome": "success", "deliverables": ["BRD-tracker.json"] },
    { "step": 6, "name": "POST-BRD Critic", "agent": "conductor-critic", "completed_at": "2025-01-15T12:45:00Z", "outcome": "success", "deliverables": ["extraction-gap-report.md"] },
    { "step": 7, "name": "Architecture Planning", "agent": "conductor-architect", "completed_at": "2025-01-15T14:00:00Z", "outcome": "success", "deliverables": ["TODO/*.md", "00-page-inventory.md", "00-link-matrix.md"] },
    { "step": 8, "name": "POST-ARCHITECT Critic", "agent": "conductor-critic", "completed_at": "2025-01-15T14:15:00Z", "outcome": "success", "deliverables": ["architecture-gap-report.md"] }
  ],
  "verification_status": {
    "post_ciso": "advisory_pass_with_findings",
    "post_extraction": "pass",
    "post_architect": "pass",
    "post_qa": null,
    "post_implementation": null,
    "pre_release": null,
    "advisory_findings": [
      { "checkpoint": "post_ciso", "findings_count": 2, "severity_breakdown": { "critical": 0, "high": 0, "medium": 2, "low": 0 }, "summary": "Rate limiting recommended for API endpoints", "timestamp": "2025-01-15T11:45:00Z" }
    ]
  },
  "checkpoints": [
    { "checkpoint_id": "chk_phase1_complete", "trigger": "phase_transition", "created_at": "2025-01-15T12:45:00Z", "phase": 1, "step": 6, "git_sha": "abc1234", "todo_count": 0, "complete_count": 0 },
    { "checkpoint_id": "chk_phase2_arch", "trigger": "phase_transition", "created_at": "2025-01-15T14:15:00Z", "phase": 2, "step": 8, "git_sha": "def5678", "todo_count": 15, "complete_count": 0 }
  ]
}
```

## Failed Step — Remediation Required

```json
{
  "current_step": { "number": 14, "name": "POST-IMPLEMENTATION Critic", "assigned_agent": "conductor-critic", "status": "blocked" },
  "remediation_loops": 2,
  "total_critic_rejections": 3,
  "failed_tasks": [
    {
      "step": 11,
      "name": "Code Generation (attempt 3)",
      "agent": "conductor-builder",
      "failure_type": "quality_failure",
      "failure_details": "Critic rejected: 3 placeholder implementations found",
      "failed_at": "2025-01-15T18:00:00Z",
      "retry_count": 3,
      "last_error": "BRD requirements REQ-012, REQ-015, REQ-018 have stub implementations",
      "escalation_status": "pending"
    }
  ]
}
```
