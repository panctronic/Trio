# Swift 6 migration plan

A living document. Trio moves to the Swift 6 language mode one target and one
module at a time; every step must build, keep the test suite green and leave
dosing behaviour unchanged. Update the numbers below whenever a phase lands.

## Where we are

- Language mode: Swift 5 in every target.
- `SWIFT_STRICT_CONCURRENCY` is not set (Xcode's default, `minimal`).
- Deployment targets: iOS 17.6, watchOS 10. `OSAllocatedUnfairLock` (iOS 16)
  is available; `Synchronization.Mutex` (iOS 18) is not.
- The Git submodules (LoopKit, the pump and CGM kits, TidepoolService, ...)
  stay in Swift 5 and are not edited here; we import them with
  `@preconcurrency` where needed.

### Warning counts

Unique warnings reported in Trio's own sources (`Trio/`, `TrioTests/`, `Model/`,
`LiveActivity/`, the watch folders) by a build of the `Trio Tests` scheme for
the iOS simulator. Duplicates (one file compiled into two targets) are counted
once. "Concurrency" means the diagnostic is about Sendable, isolation, actors
or data races.

Measured on 2026-11-20 with Xcode's Swift 6.x toolchain:

| Strict concurrency | All warnings | Concurrency warnings |
| ------------------ | -----------: | -------------------: |
| minimal (current)  |         ~180 |                 ~136 |
| targeted           |          405 |                  364 |
| complete           |         1750 |                 1709 |

Concurrency warnings under `complete`, by directory:

| Directory                  | Warnings |
| -------------------------- | -------: |
| Trio/Sources/Modules       |      561 |
| Trio/Sources/Services      |      411 |
| Trio/Sources/APS           |      214 |
| TrioTests                  |      212 |
| Trio/Sources/Router        |      119 |
| Trio Watch App Extension   |       62 |
| Trio/Sources/Shortcuts     |       27 |
| Trio/Sources/Application   |       26 |
| Model                      |       22 |
| Trio/Sources/Views         |       18 |
| Trio/Sources/Logger        |       15 |
| Trio/Sources/Helpers       |       12 |
| Trio/Sources/Models        |        8 |
| LiveActivity               |        2 |

Most frequent diagnostics under `complete`:

| Count | Diagnostic |
| ----: | ---------- |
| 465 | sending 'x' risks causing data races |
| 455 | capture of 'x' with non-Sendable type in a `@Sendable` closure |
| 147 | passing closure as a 'sending' parameter risks causing data races |
|  94 | sending value of non-Sendable type risks causing data races |
| 102 | mutation of / reference to a captured var in concurrently-executing code |
|  73 | call to a main actor-isolated initializer or method from a nonisolated context |
|  94 | static property is not concurrency-safe (shared mutable state or non-Sendable type) |
|  58 | conformance crosses into main actor-isolated code |
|  43 | add '@preconcurrency' to suppress Sendable warnings from a module (LoopKit most often) |

`targeted` adds about 230 warnings over `minimal`. The largest groups:

- ~60 `capture of 'results' with non-Sendable type 'Any'`: the storages fetch
  with `CoreDataStack.fetchEntitiesAsync`, which returns `Any`, and then cast
  the result inside `context.perform`. Fixing this means changing that API
  (return `[NSManagedObjectID]` or typed values built inside `perform`), not
  sprinkling annotations.
- ~45 `capture of 'self' with non-Sendable type '<Module>.StateModel'`:
  state models are not main-actor isolated yet (phase 3).
- 14 `non-Sendable type 'CoreDataStack' ... cannot exit main actor-isolated
  context`.
- About a fifth of the new warnings are in `APSManager`, `OpenAPS`,
  `CarbsStorage`, `AppleWatchManager` and `Treatments.StateModel`.

Because of that, `SWIFT_STRICT_CONCURRENCY = targeted` is **not** switched on
for the `Trio` target yet: it would add ~230 warnings to every build, and the
bulk of them need the Core Data API change from phase 2 rather than local
fixes.

## Phases

| Phase | Scope | Status |
| ----- | ----- | ------ |
| 0 | Measure; write this plan | done |
| 1 | Leaf targets in Swift 6 mode: LiveActivity extension, watch complication, watch app | in progress |
| 2 | Core Data boundary: storages return `NSManagedObjectID`s or Sendable value snapshots; remove `Any` from `fetchEntitiesAsync`; `CoreDataStack` Sendable | todo |
| 3 | State models: `@Observable` + `@MainActor` (needs `BaseStateModel` and `Router` on the main actor first) | todo |
| 4 | Turn on `targeted` for `Trio`, then fix the remaining warnings module by module | todo |
| 5 | `complete` for `Trio`; services get explicit isolation (actor, `@MainActor`, or documented queue) | todo |
| 6 | Swift 6 language mode for `Trio` and `TrioTests` | todo |

## Conventions

- **Pump and loop work stays on `processQueue`.** `BaseAPSManager`,
  `BaseDeviceDataManager` and the pump manager delegates run on
  `processQueue`; LoopKit pump managers call back on it. Do not move this to
  an actor or to `MainActor` as part of the migration. Mark these types
  `@unchecked Sendable` only with a comment naming the queue that protects
  them.
- **Storages talk via `NSManagedObjectID`.** Managed objects never leave the
  context that fetched them. Pass object IDs (Sendable) or plain value
  structs across tasks and actors; refetch on the destination context.
- **`@preconcurrency import LoopKit`** (and the other submodules) where a
  file needs LoopKit types to cross isolation. Do not add `Sendable`
  conformances to submodule types from Trio.
- **Locks:** prefer `OSAllocatedUnfairLock(initialState:)` with
  `withLock { }` over `NSLock` + a separate `var`. A class whose only mutable
  state sits inside such a lock is genuinely `Sendable`; no `@unchecked`.
- **Shared constants are `static let`**, never `static var`. A `static var`
  must be isolated (`@MainActor`) or protected by a lock.
- **Value types crossing threads are `Sendable`.** Internal structs and enums
  get it inferred; public ones and ones with `Any` members need a decision.
- **No `nonisolated(unsafe)`** unless a comment explains what makes the
  access safe. Same for `@unchecked Sendable`.
- **Views and UI state are `@MainActor`.** New state models use
  `@Observable`; mark them `@MainActor` once `BaseStateModel` is.
- **Measure before and after.** To reproduce the numbers above, build with
  `SWIFT_STRICT_CONCURRENCY=complete` (or `targeted`) passed to
  `xcodebuild` and count unique `warning:` lines under Trio's own folders.
  Passing the setting on the command line applies it to the submodules too,
  so filter by path.
