import SwiftUI
import Swinject

extension SyncStatus {
    struct RootView: BaseView {
        let resolver: Resolver

        @State var state = StateModel()

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        var body: some View {
            List {
                Section {
                    Text(
                        "Shows whether Trio's uploads are reaching Nightscout, Tidepool and Apple Health, so followers and your care team see complete data."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)

                if state.rows.isEmpty {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    }
                    .listRowBackground(Color.chart)
                } else {
                    ForEach(state.rows) { row in
                        DestinationSection(
                            row: row,
                            now: state.now,
                            retryRequested: state.retryRequested.contains(row.destination),
                            retry: { state.retry(row.destination) }
                        )
                    }
                }

                Section {
                    Text(
                        "Records that could not be uploaded are retried for \(UploadBacklog.nightscoutDays) days (Nightscout) or \(UploadBacklog.tidepoolDays) days (Tidepool and Apple Health). Older records are not uploaded."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
            }
            .listSectionSpacing(sectionSpacing)
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .refreshable { state.refresh() }
            .onAppear {
                configureView()
                state.refresh()
            }
            .navigationTitle("Sync Status")
            .navigationBarTitleDisplayMode(.automatic)
        }
    }
}

// MARK: - Destination section

private struct DestinationSection: View {
    let row: SyncStatus.DestinationRow
    let now: Date
    let retryRequested: Bool
    let retry: () -> Void

    var body: some View {
        Section(header: Text(row.destination.displayName)) {
            StatusLine(destination: row.destination, health: row.health)

            if case let .blocked(message) = row.availability {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }

            if row.availability != .off {
                InfoRow(
                    label: String(localized: "Last upload"),
                    value: row.record.lastSuccessDate.map { relative($0) } ?? String(localized: "None recorded")
                )

                if let failure = row.record.latestFailure {
                    VStack(alignment: .leading, spacing: 4) {
                        InfoRow(
                            label: String(localized: "Last error"),
                            value: "\(failure.kind.displayName), \(relative(failure.date))"
                        )
                        Text(failure.message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                }

                backlogRows

                DisclosureGroup("Details") {
                    ForEach(row.destination.dataKinds) { kind in
                        KindRow(
                            kind: kind,
                            lastSuccess: row.record.lastSuccess[kind],
                            failure: row.record.failures[kind],
                            pending: kind == .deviceStatus ? nil : row.backlog?.pendingByKind[kind],
                            relative: relative
                        )
                    }
                }

                Button(action: retry) {
                    Label(
                        retryRequested ? String(localized: "Upload requested") : String(localized: "Retry now"),
                        systemImage: retryRequested ? "checkmark" : "arrow.clockwise"
                    )
                }
                .disabled(retryRequested)
                .accessibilityHint(
                    Text("Asks Trio to upload the records waiting for \(row.destination.displayName) now.")
                )
            } else {
                Text("Not set up, or uploads are switched off.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .listRowBackground(Color.chart)
    }

    @ViewBuilder private var backlogRows: some View {
        if let backlog = row.backlog {
            InfoRow(label: String(localized: "Waiting to upload"), value: backlog.pendingUploads.formatted())

            if let oldest = backlog.oldestPending {
                InfoRow(label: String(localized: "Oldest waiting"), value: relative(oldest))
            }

            if row.isNearWindowLimit, let windowEnd = row.windowEnd {
                Label {
                    Text(
                        windowEnd <= now ?
                            String(
                                localized: "The oldest waiting records have left the upload window and will not be uploaded."
                            ) :
                            String(
                                localized: "The oldest waiting records leave the upload window \(relative(windowEnd)). After that they will not be uploaded."
                            )
                    )
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.subheadline)
                .foregroundStyle(.orange)
                .accessibilityElement(children: .combine)
            }

            if backlog.pendingDeletions > 0 {
                InfoRow(
                    label: String(localized: "Deletions waiting"),
                    value: backlog.pendingDeletions.formatted()
                )
            }
        } else {
            InfoRow(label: String(localized: "Waiting to upload"), value: String(localized: "Unknown"))
        }
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: max(now, Date()))
    }
}

// MARK: - Building blocks

private struct StatusLine: View {
    let destination: SyncDestination
    let health: SyncHealth

    var body: some View {
        Label {
            Text(title).fontWeight(.semibold)
        } icon: {
            Image(systemName: icon).foregroundStyle(color)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(destination.displayName) status"))
        .accessibilityValue(Text(title))
    }

    private var title: String {
        switch health {
        case .ok: return String(localized: "OK", comment: "Sync status: uploads are up to date")
        case .behind: return String(localized: "Behind", comment: "Sync status: records are waiting to upload")
        case .error: return String(localized: "Error", comment: "Sync status: uploads are failing")
        case .off: return String(localized: "Off", comment: "Sync status: destination not set up")
        }
    }

    private var icon: String {
        switch health {
        case .ok: return "checkmark.circle.fill"
        case .behind: return "hourglass.circle.fill"
        case .error: return "xmark.octagon.fill"
        case .off: return "minus.circle"
        }
    }

    private var color: Color {
        switch health {
        case .ok: return .green
        case .behind: return .orange
        case .error: return .red
        case .off: return .secondary
        }
    }
}

/// Label and value side by side, stacked at accessibility text sizes.
private struct InfoRow: View {
    let label: String
    let value: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize ?
            AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) :
            AnyLayout(HStackLayout(alignment: .firstTextBaseline))
        layout {
            Text(label)
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct KindRow: View {
    let kind: SyncDataKind
    let lastSuccess: Date?
    let failure: SyncFailure?
    /// `nil` when not counted for this kind.
    let pending: Int?
    let relative: (Date) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(kind.displayName).font(.subheadline.weight(.semibold))
            Text(lastSuccess.map { String(localized: "Last upload \(relative($0))") } ?? String(localized: "No upload recorded"))
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let pending, pending > 0 {
                Text("\(pending) waiting")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if let failure {
                Text("Failed \(relative(failure.date)): \(failure.message)")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
