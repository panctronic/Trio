# Swift 6 migration plan

A living document. Trio moves to the Swift 6 language mode one target and one
module at a time; every step must build, keep the test suite green and leave
dosing behaviour unchanged. Update the numbers below whenever a phase lands.

## Where we are

- Language mode: Swift 6 for `LiveActivityExtension`, `Trio Watch Complication
  Extension` and `Trio Watch App`; Swift 5 for `Trio` and `TrioTests`.
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

After phase 1 (watch and Live Activity targets in Swift 6, constant
`static let`s, lock cleanups): `complete` reports 1662 warnings, 1621 of
them concurrency-related, none in the three Swift 6 targets.

After the Core Data fetch API change (phase 2, first part), measured on
2026-11-20 under `targeted`:

| Strict concurrency | All warnings | Concurrency warnings |
| ------------------ | -----------: | -------------------: |
| targeted, before   |          409 |                  368 |
| targeted, after    |          279 |                  250 |

Concurrency warnings under `targeted`, by directory:

| Directory                 | Before | After |
| ------------------------- | -----: | ----: |
| Trio/Sources/APS          |    107 |    65 |
| Trio/Sources/Modules      |    104 |    77 |
| Trio/Sources/Services     |     72 |    41 |
| TrioTests                 |     62 |    63 |
| Trio/Sources/Application  |     15 |     1 |
| Model                     |      7 |     3 |
| Trio/Sources/Helpers      |      1 |     0 |

No `capture of ... with non-Sendable type 'Any'` warning is left. The
remaining `targeted` warnings in Trio's sources (187, plus 63 in tests) are
mostly captures of non-Sendable `self` in `perform`/`Task` closures: 56 of
them are `<Module>.StateModel` (phase 3), the rest storages, managers and
test classes that are not `Sendable` yet.

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

Before the Core Data fetch API change, `targeted` added about 230 warnings
over `minimal`. The largest groups were:

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

The fetch helper now returns typed results (see "Core Data fetches" below)
and `CoreDataStack` is `@unchecked Sendable`, which removed the first and
third group. `SWIFT_STRICT_CONCURRENCY = targeted` is still **not** switched
on for the `Trio` target: it would add ~100 warnings over `minimal` to every
build, most of them state model captures that phase 3 removes wholesale.

## Phases

| Phase | Scope | Status |
| ----- | ----- | ------ |
| 0 | Measure; write this plan | done |
| 1 | Leaf targets in Swift 6 mode: LiveActivity extension, watch complication, watch app | done |
| 2 | Core Data boundary: storages return `NSManagedObjectID`s or Sendable value snapshots; remove `Any` from `fetchEntitiesAsync`; `CoreDataStack` Sendable | in progress: typed fetch helpers and `CoreDataStack` Sendable done; `TDDSetup` and the state shortcut still pass managed objects between blocks |
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
- **Core Data fetches** go through the typed helpers on `CoreDataStack`:
  `fetchAndMap(ofType:...) { objects in ... }` runs the fetch and the
  closure in one `context.perform` and returns whatever the closure builds
  (value types or object IDs); `fetchObjectIDs` and
  `fetchDictionaries(..., propertiesToFetch:) { rows in ... }` cover the
  common cases. `fetchObjects` returns the managed objects themselves and
  is only for code that keeps working on the same context (tests, the view
  context on the main actor). `fetchObjectsAndWait` /
  `fetchDictionariesAndWait` are for code already on the context's queue.
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
