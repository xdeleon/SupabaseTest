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
