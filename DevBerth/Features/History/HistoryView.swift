import SwiftData
import SwiftUI

private enum HistoryRange: String, CaseIterable { case all = "All Time", today = "Today", week = "7 Days", month = "30 Days" }
private enum HistoryGrouping: String, CaseIterable { case none = "No Grouping", day = "Day", event = "Event Type" }
private enum HistoryTimeline: String, CaseIterable { case lifecycle = "Lifecycle", actions = "Ports & Actions" }

struct HistoryView: View {
    private static let fetchLimit = 100
    @Environment(\.modelContext) private var context
    @Query private var profiles: [LaunchProfileRecord]
    @Query private var dependencies: [ProfileDependencyRecord]
    @Query private var expectedPorts: [ExpectedPortRecord]
    @Query private var processPolicies: [ManagedServiceProcessPolicyRecord]
    @Query private var serviceChecks: [ManagedServiceCheckRecord]
    @State private var events: [ProcessHistoryEventRecord] = []
    @State private var lifecycleEvents: [LifecycleEventRecord] = []
    @State private var incidents: [RuntimeIncidentSummaryRecord] = []
    @State private var eventType: HistoryEventType?
    @State private var severity: LifecycleEventSeverity?
    @State private var timeline = HistoryTimeline.lifecycle
    @State private var range = HistoryRange.week
    @State private var grouping = HistoryGrouping.none
    @State private var searchText = ""
    @State private var selection = Set<UUID>()
    @State private var confirmsClearAll = false
    @State private var lifecycleContextSnapshots: [LifecycleHistoryContextSnapshot] = []
    @State private var presentedErrorMessage: String?

    private var filtered: [ProcessHistoryEventRecord] {
        let cutoff = cutoff
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return events.filter { event in
            let matchesType = eventType == nil || event.typeRawValue == eventType?.rawValue
            let matchesDate = cutoff.map { event.timestamp >= $0 } ?? true
            guard matchesType, matchesDate else { return false }
            guard !query.isEmpty else { return true }
            let haystack = [
                event.typeRawValue,
                event.processName ?? "",
                event.port.map(String.init) ?? "",
                event.errorDetails ?? ""
            ].joined(separator: " ")
            return haystack.localizedCaseInsensitiveContains(query)
        }
    }

    private var filteredLifecycle: [LifecycleHistoryRow] {
        LifecycleHistoryPresentation.rows(
            events: lifecycleEvents.map {
                LifecycleHistoryEventSnapshot(
                    id: $0.id,
                    timestamp: $0.timestamp,
                    managedServiceID: $0.managedServiceID,
                    categoryRawValue: $0.categoryRawValue,
                    outcomeRawValue: $0.outcomeRawValue,
                    summary: $0.summary
                )
            },
            contexts: lifecycleContextSnapshots,
            severity: severity,
            cutoff: cutoff,
            searchText: searchText
        )
    }

    private var cutoff: Date? {
        switch range {
        case .all: nil
        case .today: Calendar.current.startOfDay(for: Date())
        case .week: Calendar.current.date(byAdding: .day, value: -7, to: Date())
        case .month: Calendar.current.date(byAdding: .day, value: -30, to: Date())
        }
    }

    private var displayedPageIsLimited: Bool {
        timeline == .lifecycle
            ? lifecycleEvents.count == Self.fetchLimit
            : events.count == Self.fetchLimit
    }

    var body: some View {
        let lifecycleRows = filteredLifecycle
        let actionRows = filtered
        let displayedCount = timeline == .lifecycle ? lifecycleRows.count : actionRows.count

        VStack(spacing: 0) {
            historyControls(displayedCount: displayedCount)
            Divider()
            Group {
                if timeline == .lifecycle && lifecycleRows.isEmpty {
                    EmptyStateView(
                        symbol: searchText.isEmpty ? "waveform.path.ecg" : "magnifyingglass",
                        title: searchText.isEmpty ? "No lifecycle events" : "No matching lifecycle events",
                        message: "Managed launches, readiness, health, exits, restarts, and incidents appear here."
                    )
                } else if timeline == .lifecycle {
                    lifecycleTimeline(lifecycleRows)
                } else if actionRows.isEmpty {
                    EmptyStateView(
                        symbol: searchText.isEmpty ? "clock.arrow.circlepath" : "magnifyingglass",
                        title: searchText.isEmpty ? "No history events" : "No matching events",
                        message: "Port changes, launches, health checks, and process actions are recorded locally."
                    )
                } else if grouping == .none {
                    actionTable(actionRows)
                } else {
                    groupedList(actionRows)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("History")
        .task {
            refreshHistory()
        }
        .confirmationDialog("Clear all DevBerth history?", isPresented: $confirmsClearAll, titleVisibility: .visible) {
            Button("Clear All History", role: .destructive) {
                clearAllHistory()
                selection.removeAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Projects and managed services will not be deleted. This history cannot be recovered.") }
        .alert(
            "History couldn’t be updated",
            isPresented: Binding(
                get: { presentedErrorMessage != nil },
                set: { if !$0 { presentedErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(presentedErrorMessage ?? "An unexpected error occurred.")
        }
    }

    private func historyControls(displayedCount: Int) -> some View {
        VStack(spacing: DevBerthSpacing.medium) {
            HStack(spacing: DevBerthSpacing.medium) {
                Picker("Timeline", selection: $timeline) {
                    ForEach(HistoryTimeline.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)

                Text("\(displayedCount) events")
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                if displayedPageIsLimited {
                    Label("Newest \(Self.fetchLimit)", systemImage: "clock")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: DevBerthSpacing.medium)

                Button {
                    refreshHistory()
                } label: {
                    Label("Refresh History", systemImage: "arrow.clockwise")
                }
                HistoryRestartButton(configuration: relatedConfiguration)
                Menu {
                    Button(role: .destructive) {
                        clearSelected()
                    } label: {
                        Label("Clear Selected", systemImage: "trash")
                    }
                    .disabled(selection.isEmpty)
                    Divider()
                    Button(role: .destructive) {
                        confirmsClearAll = true
                    } label: {
                        Label("Clear All History", systemImage: "trash.slash")
                    }
                    .disabled(events.isEmpty && lifecycleEvents.isEmpty)
                } label: {
                    Label("History Actions", systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            HStack(spacing: DevBerthSpacing.medium) {
                HStack(spacing: DevBerthSpacing.small) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search this history", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button("Clear Search", systemImage: "xmark.circle.fill") {
                            searchText = ""
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, DevBerthSpacing.medium)
                .padding(.vertical, DevBerthSpacing.small)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .frame(minWidth: 240, idealWidth: 320, maxWidth: 420)

                Picker("Date range", selection: $range) {
                    ForEach(HistoryRange.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 170)

                if timeline == .lifecycle {
                    Picker("Severity", selection: $severity) {
                        Text("All Severities").tag(nil as LifecycleEventSeverity?)
                        ForEach(LifecycleEventSeverity.allCases, id: \.self) {
                            Text($0.rawValue.capitalized).tag($0 as LifecycleEventSeverity?)
                        }
                    }
                    .frame(width: 200)
                } else {
                    Picker("Event type", selection: $eventType) {
                        Text("All Events").tag(nil as HistoryEventType?)
                        ForEach(HistoryEventType.allCases, id: \.self) {
                            Text(humanized($0.rawValue)).tag($0 as HistoryEventType?)
                        }
                    }
                    .frame(width: 220)

                    Picker("Group", selection: $grouping) {
                        ForEach(HistoryGrouping.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .frame(width: 180)
                }

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, DevBerthSpacing.large)
        .padding(.vertical, DevBerthSpacing.medium)
        .background(.bar)
    }

    private func lifecycleTimeline(_ rows: [LifecycleHistoryRow]) -> some View {
        let serviceNames = profiles.reduce(into: [UUID: String]()) { names, profile in
            names[profile.id] = profile.name
        }
        return Group {
            if let incident = selectedIncident {
                HSplitView {
                    lifecycleTable(rows, serviceNames: serviceNames)
                        .frame(minWidth: 720, maxWidth: .infinity, maxHeight: .infinity)
                    LifecycleIncidentView(incident: incident)
                        .frame(minWidth: 280, idealWidth: 340, maxWidth: 430, maxHeight: .infinity)
                }
            } else {
                lifecycleTable(rows, serviceNames: serviceNames)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func lifecycleTable(_ rows: [LifecycleHistoryRow], serviceNames: [UUID: String]) -> some View {
        Table(rows, selection: $selection) {
            TableColumn("Time") {
                Text($0.timestamp, format: .dateTime.month().day().hour().minute().second())
            }
            .width(min: 125, ideal: 150)
            TableColumn("Severity") { event in
                let value = event.severityRawValue
                Label(value.capitalized, systemImage: severitySymbol(value))
                    .foregroundStyle(severityColor(value))
            }
            .width(min: 85, ideal: 100)
            TableColumn("Event") { Text(humanized($0.categoryRawValue)) }
            TableColumn("Service") { event in
                Text(profileName(for: event.managedServiceID, serviceNames: serviceNames))
            }
            TableColumn("Source") { event in
                Text(humanized(event.sourceRawValue))
            }
            TableColumn("Summary", value: \.summary)
            TableColumn("Result") { Text($0.outcomeRawValue.capitalized) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func actionTable(_ rows: [ProcessHistoryEventRecord]) -> some View {
        Table(rows, selection: $selection) {
            TableColumn("Time") { Text($0.timestamp, format: .dateTime.month().day().hour().minute().second()) }
            TableColumn("Event") { Text(humanized($0.typeRawValue)) }
            TableColumn("Process") { Text($0.processName ?? "—") }
            TableColumn("Port") { Text($0.port.map(String.init) ?? "—").monospacedDigit() }
            TableColumn("Result") { Text($0.resultRawValue.capitalized) }
            TableColumn("Details") { Text($0.errorDetails ?? "—").foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func groupedList(_ rows: [ProcessHistoryEventRecord]) -> some View {
        let groups = Dictionary(grouping: rows) { event -> String in
            switch grouping {
            case .day: event.timestamp.formatted(.dateTime.year().month().day())
            case .event: humanized(event.typeRawValue)
            case .none: ""
            }
        }
        return List(selection: $selection) {
            ForEach(groups.keys.sorted(by: >), id: \.self) { key in
                Section(key) {
                    ForEach(groups[key] ?? []) { event in
                        HStack {
                            Text(event.timestamp, format: .dateTime.hour().minute().second()).monospacedDigit().foregroundStyle(.secondary)
                            Text(humanized(event.typeRawValue)).frame(width: 160, alignment: .leading)
                            Text(event.processName ?? "—")
                            Spacer()
                            Text(event.port.map { ":\($0)" } ?? "").monospacedDigit()
                            Text(event.resultRawValue.capitalized).foregroundStyle(.secondary)
                        }
                        .tag(event.id)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var relatedConfiguration: ManagedServiceConfiguration? {
        guard let selectedID = selection.first else { return nil }
        let profileID: UUID? = {
            if timeline == .lifecycle {
                return lifecycleEvents.first { $0.id == selectedID }?.managedServiceID
            }
            return events.first { $0.id == selectedID }?.profileID
        }()
        guard
            let profileID,
            let profile = profiles.first(where: { $0.id == profileID })
        else { return nil }
        return profile.configuration(
            dependencies: dependencies,
            expectedPorts: expectedPorts,
            processPolicies: processPolicies,
            serviceChecks: serviceChecks
        )
    }

    private func clearSelected() {
        if timeline == .lifecycle {
            let ids = selection
            lifecycleEvents.filter { ids.contains($0.id) }.forEach(context.delete)
            let descriptor = FetchDescriptor<LifecycleEventContextRecord>(
                predicate: #Predicate { ids.contains($0.lifecycleEventID) }
            )
            (try? context.fetch(descriptor))?.forEach(context.delete)
        } else {
            events.filter { selection.contains($0.id) }.forEach(context.delete)
        }
        try? context.save()
        selection.removeAll()
        refreshHistory()
    }

    private func refreshHistory() {
        do {
            var processDescriptor = FetchDescriptor<ProcessHistoryEventRecord>(
                sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
            )
            processDescriptor.fetchLimit = Self.fetchLimit

            var lifecycleDescriptor = FetchDescriptor<LifecycleEventRecord>(
                sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
            )
            lifecycleDescriptor.fetchLimit = Self.fetchLimit

            var incidentDescriptor = FetchDescriptor<RuntimeIncidentSummaryRecord>(
                sortBy: [SortDescriptor(\.generatedAt, order: .reverse)]
            )
            incidentDescriptor.fetchLimit = 250

            let refreshedEvents = try context.fetch(processDescriptor)
            let refreshedLifecycleEvents = try context.fetch(lifecycleDescriptor)
            let refreshedIncidents = try context.fetch(incidentDescriptor)
            let ids = Set(refreshedLifecycleEvents.map(\.id))
            let refreshedContexts: [LifecycleHistoryContextSnapshot]
            if ids.isEmpty {
                refreshedContexts = []
            } else {
                let contextDescriptor = FetchDescriptor<LifecycleEventContextRecord>(
                    predicate: #Predicate { ids.contains($0.lifecycleEventID) }
                )
                refreshedContexts = try context.fetch(contextDescriptor).map {
                    LifecycleHistoryContextSnapshot(
                        lifecycleEventID: $0.lifecycleEventID,
                        severityRawValue: $0.severityRawValue,
                        sourceRawValue: $0.sourceRawValue
                    )
                }
            }

            events = refreshedEvents
            lifecycleEvents = refreshedLifecycleEvents
            incidents = refreshedIncidents
            lifecycleContextSnapshots = refreshedContexts
        } catch {
            presentedErrorMessage = error.localizedDescription
        }
    }

    private func clearAllHistory() {
        do {
            try context.delete(model: ProcessHistoryEventRecord.self, where: #Predicate { _ in true })
            try context.delete(model: LifecycleEventRecord.self, where: #Predicate { _ in true })
            try context.delete(model: LifecycleEventContextRecord.self, where: #Predicate { _ in true })
            try context.delete(model: RuntimeIncidentSummaryRecord.self, where: #Predicate { _ in true })
            try context.save()
            events = []
            lifecycleEvents = []
            incidents = []
            lifecycleContextSnapshots = []
        } catch {
            presentedErrorMessage = error.localizedDescription
        }
    }

    private var selectedIncident: RuntimeIncidentSummary? {
        guard let selectedID = selection.first,
              let selectedEvent = lifecycleEvents.first(where: { $0.id == selectedID }),
              let serviceID = selectedEvent.managedServiceID else { return nil }
        return incidents.first {
            $0.managedServiceID == serviceID
                && ($0.summary?.relatedEventIDs.contains(selectedEvent.id) == true)
        }?.summary ?? incidents.first { $0.managedServiceID == serviceID }?.summary
    }

    private func profileName(for id: UUID?, serviceNames: [UUID: String]) -> String {
        guard let id else { return "—" }
        return serviceNames[id] ?? String(id.uuidString.prefix(8))
    }

    private func severitySymbol(_ value: String) -> String {
        switch LifecycleEventSeverity(rawValue: value) {
        case .warning: "exclamationmark.triangle.fill"
        case .error, .critical: "xmark.octagon.fill"
        case .notice: "bell.fill"
        default: "info.circle"
        }
    }

    private func severityColor(_ value: String) -> Color {
        switch LifecycleEventSeverity(rawValue: value) {
        case .warning: .orange
        case .error, .critical: .red
        case .notice: .blue
        default: .secondary
        }
    }

    private func humanized(_ value: String) -> String {
        value.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized
    }
}

private struct HistoryRestartButton: View {
    @EnvironmentObject private var model: AppModel
    let configuration: ManagedServiceConfiguration?

    var body: some View {
        Button {
            guard let configuration else { return }
            Task { await model.launchProfile(configuration) }
        } label: {
            Label("Restart Service", systemImage: "play")
        }
        .disabled(configuration == nil)
    }
}

private struct LifecycleIncidentView: View {
    let incident: RuntimeIncidentSummary

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DevBerthSpacing.large) {
                Label(incident.title, systemImage: "exclamationmark.bubble.fill")
                    .font(.title3.bold()).foregroundStyle(.orange)
                GroupBox("Determined cause") {
                    Text(incident.cause)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Evidence timeline") {
                    VStack(alignment: .leading, spacing: DevBerthSpacing.medium) {
                        ForEach(Array(incident.steps.enumerated()), id: \.element.id) { index, step in
                            HStack(alignment: .top, spacing: DevBerthSpacing.small) {
                                Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(step.explanation).font(.callout)
                                    Text(step.timestamp.formatted())
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Suggested next action") {
                    Text(incident.suggestedAction)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
    }
}
