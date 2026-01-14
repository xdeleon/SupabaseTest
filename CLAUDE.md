# Project Guidelines (Sync)

## Priorities
1. NO generic/abstract sync code - keep explicit per-model methods for debuggability.
2. Offline-first required - local writes first, enqueue PendingChange, background sync.
3. Simple over clever - copy-paste is acceptable.

## Sync Behavior
- Local SwiftData is the source of truth for writes.
- Supabase sync runs from the PendingChange queue.
- NetworkMonitor triggers queue processing on reconnect.
- Realtime applies remote changes using "upsert by id".
- Sync ordering matters: classes must sync before students.
- Error policy: log and continue, surface via lastSyncError (or document fail-fast).

## Soft Delete & Audit
- Use soft delete: set deleted_at + deleted_by instead of hard delete.
- Reads must filter deleted_at IS NULL by default; "undelete" clears deleted_at.
- Treat remote deletes as conflicts with local PendingChange; surface and skip child sync.
- Track last edit server-side with updated_at + updated_by (do not store userId locally).
- For full history, use an audit_logs table (row_id, action, actor_id, at, before/after).

## Files
- SyncManager.swift - all sync logic, explicit per-model methods.
- PendingChange.swift - offline queue model (must be used).
- NetworkMonitor.swift - connectivity detection.

## Avoid
- Generic SyncHandler/SyncDescriptor/registry patterns.
- Type erasure or protocol-heavy abstractions for sync.
- Sourcery/codegen.
- "Cleanup" that reduces debuggability.

## Adding Models
Copy the SchoolClass/Student pattern. Repetition is intentional.

## Minimum Tests
- Record mapping test (Supabase record -> local model).
- Initial sync with mock RemoteStore.
- Realtime insert handling.

## User Switching
- Clear all local SwiftData on logout
- Clear PendingChange queue on logout
- Each model does NOT store userId locally (we clear instead)
