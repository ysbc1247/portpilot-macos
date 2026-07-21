import SwiftData
import SwiftUI

private enum HistoryRange: String, CaseIterable { case all = "All Time", today = "Today", week = "7 Days", month = "30 Days" }
private enum HistoryGrouping: String, CaseIterable { case none = "No Grouping", day = "Day", event = "Event Type" }
private enum HistoryTimeline: String, CaseIterable { case lifecycle = "Lifecycle", actions = "Ports & Actions" }

struct HistoryView: View {
    private static let fetchLimit = 500
    @EnvironmentObject private var model: AppModel
    @Environment(\.modelContext) private var context
    @Query private var events: [ProcessHistoryEventRecord]
    @Query private var lifecycleEvents: [LifecycleEventRecord]
    @Query(sort: \RuntimeIncidentSummaryRecord.generatedAt, order: .reverse) private var incidents: [RuntimeIncidentSummaryRecord]
    @Query private var profiles: [LaunchProfileRecord]
    @Query private var dependencies: [ProfileDependencyRecord]
    @Query private var expectedPorts: [ExpectedPortRecord]
    @Query private var processPolicies: [ManagedServiceProcessPolicyRecord]
    @Query private var serviceChecks: [ManagedServiceCheckRecord]
    @State private var eventType: HistoryEventType?
    @State private var severity: LifecycleEventSeverity?
    @State private var timeline = HistoryTimeline.lifecycle
    @State private var range = HistoryRange.week
    @State private var grouping = HistoryGrouping.none
    @State private var searchText = ""
    @State private var selection = Set<UUID>()
    @State private var confirmsClearAll = false
    @State private var lifecycleContextSnapshots: [LifecycleHistoryContextSnapshot] = []

    init() {
        var processDescriptor = FetchDescriptor<ProcessHistoryEventRecord>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        processDescriptor.fetchLimit = Self.fetchLimit
        _events = Query(processDescriptor)

        var lifecycleDescriptor = FetchDescriptor<LifecycleEventRecord>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        lifecycleDescriptor.fetchLimit = Self.fetchLimit
        _lifecycleEvents = Query(lifecycleDescriptor)
    }

    private var filtered: [ProcessHistoryEventRecord] {
        events.filter { event in
            let matchesType = eventType == nil || event.typeRawValue == eventType?.rawValue
            let cutoff: Date? = {
                switch range {
                case .all: nil
                case .today: Calendar.current.startOfDay(for: Date())
                case .week: Calendar.current.date(byAdding: .day, value: -7, to: Date())
                case .month: Calendar.current.date(byAdding: .day, value: -30, to: Date())
                }
            }()
            let matchesDate = cutoff.map { event.timestamp >= $0 } ?? true
            let haystack = [event.typeRawValue, event.processName ?? "", event.port.map(String.init) ?? "", event.errorDetails ?? ""].joined(separator: " ")
            let matchesSearch = searchText.isEmpty || haystack.localizedCaseInsensitiveContains(searchText)
            return matchesType && matchesDate && matchesSearch
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
        Group {
            if timeline == .lifecycle && lifecycleRows.isEmpty {
                EmptyStateView(
                    symbol: searchText.isEmpty ? "waveform.path.ecg" : "magnifyingglass",
                    title: searchText.isEmpty ? "No lifecycle events" : "No matching lifecycle events",
                    message: "Managed launches, readiness, health, exits, restarts, and incidents appear here."
                )
            } else if timeline == .lifecycle {
                lifecycleTimeline(lifecycleRows)
            } else if filtered.isEmpty {
                EmptyStateView(
                    symbol: searchText.isEmpty ? "clock.arrow.circlepath" : "magnifyingglass",
                    title: searchText.isEmpty ? "No history events" : "No matching events",
                    message: "Port changes, launches, health checks, and process actions are recorded locally."
                )
            } else if grouping == .none {
                table
            } else {
                groupedList
            }
        }
        .navigationTitle("History")
        .task(id: lifecycleEvents.map(\.id)) {
            loadLifecycleContexts()
        }
        .toolbar {
            Picker("Timeline", selection: $timeline) {
                ForEach(HistoryTimeline.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            if displayedPageIsLimited {
                Text("Latest \(Self.fetchLimit)")
                    .foregroundStyle(.secondary)
            }
            TextField("Search history", text: $searchText).textFieldStyle(.roundedBorder).frame(width: 180)
            Picker("Date range", selection: $range) { ForEach(HistoryRange.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            if timeline == .lifecycle {
                Picker("Severity", selection: $severity) {
                    Text("All Severities").tag(nil as LifecycleEventSeverity?)
                    ForEach(LifecycleEventSeverity.allCases, id: \.self) {
                        Text($0.rawValue.capitalized).tag($0 as LifecycleEventSeverity?)
                    }
                }
            } else {
                Picker("Event type", selection: $eventType) {
                    Text("All Events").tag(nil as HistoryEventType?)
                    ForEach(HistoryEventType.allCases, id: \.self) { Text(humanized($0.rawValue)).tag($0 as HistoryEventType?) }
                }
            }
            if timeline == .actions {
                Picker("Group", selection: $grouping) { ForEach(HistoryGrouping.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            }
            Button("Restart Related Managed Service", systemImage: "play") { restartSelected() }
                .disabled(relatedConfiguration == nil)
            Button("Clear Selected", role: .destructive) { clearSelected() }
                .disabled(selection.isEmpty)
            Button("Clear All", role: .destructive) { confirmsClearAll = true }
                .disabled(events.isEmpty && lifecycleEvents.isEmpty)
        }
        .confirmationDialog("Clear all DevBerth history?", isPresented: $confirmsClearAll, titleVisibility: .visible) {
            Button("Clear All History", role: .destructive) {
                clearAllHistory()
                selection.removeAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Projects and managed services will not be deleted. This history cannot be recovered.") }
    }

    private func lifecycleTimeline(_ rows: [LifecycleHistoryRow]) -> some View {
        HSplitView {
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
                    Text(profileName(for: event.managedServiceID))
                }
                TableColumn("Source") { event in
                    Text(humanized(event.sourceRawValue))
                }
                TableColumn("Summary", value: \.summary)
                TableColumn("Result") { Text($0.outcomeRawValue.capitalized) }
            }
            .frame(minWidth: 720)

            if let incident = selectedIncident {
                LifecycleIncidentView(incident: incident)
                    .frame(minWidth: 280, idealWidth: 340, maxWidth: 430)
            } else {
                ContentUnavailableView(
                    "No related incident",
                    systemImage: "checkmark.circle",
                    description: Text("Select a failed or degraded event to inspect its ordered evidence.")
                )
                .frame(minWidth: 280, idealWidth: 340, maxWidth: 430)
            }
        }
    }

    private var table: some View {
        Table(filtered, selection: $selection) {
            TableColumn("Time") { Text($0.timestamp, format: .dateTime.month().day().hour().minute().second()) }
            TableColumn("Event") { Text(humanized($0.typeRawValue)) }
            TableColumn("Process") { Text($0.processName ?? "—") }
            TableColumn("Port") { Text($0.port.map(String.init) ?? "—").monospacedDigit() }
            TableColumn("Result") { Text($0.resultRawValue.capitalized) }
            TableColumn("Details") { Text($0.errorDetails ?? "—").foregroundStyle(.secondary) }
        }
    }

    private var groupedList: some View {
        let groups = Dictionary(grouping: filtered) { event -> String in
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
    }

    private var relatedConfiguration: ManagedServiceConfiguration? {
        let profileID: UUID? = {
            if timeline == .lifecycle {
                return lifecycleEvents.first { selection.contains($0.id) }?.managedServiceID
            }
            return events.first { selection.contains($0.id) }?.profileID
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

    private func restartSelected() {
        guard let relatedConfiguration else { return }
        Task { await model.launchProfile(relatedConfiguration) }
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
    }

    private func loadLifecycleContexts() {
        let ids = Set(lifecycleEvents.map(\.id))
        guard !ids.isEmpty else {
            lifecycleContextSnapshots = []
            return
        }
        let descriptor = FetchDescriptor<LifecycleEventContextRecord>(
            predicate: #Predicate { ids.contains($0.lifecycleEventID) }
        )
        lifecycleContextSnapshots = ((try? context.fetch(descriptor)) ?? []).map {
            LifecycleHistoryContextSnapshot(
                lifecycleEventID: $0.lifecycleEventID,
                severityRawValue: $0.severityRawValue,
                sourceRawValue: $0.sourceRawValue
            )
        }
    }

    private func clearAllHistory() {
        do {
            try context.delete(model: ProcessHistoryEventRecord.self, where: #Predicate { _ in true })
            try context.delete(model: LifecycleEventRecord.self, where: #Predicate { _ in true })
            try context.delete(model: LifecycleEventContextRecord.self, where: #Predicate { _ in true })
            try context.delete(model: RuntimeIncidentSummaryRecord.self, where: #Predicate { _ in true })
            try context.save()
            lifecycleContextSnapshots = []
        } catch {
            model.presentedError = .unexpected(error.localizedDescription)
        }
    }

    private var selectedIncident: RuntimeIncidentSummary? {
        guard let selectedEvent = lifecycleEvents.first(where: { selection.contains($0.id) }),
              let serviceID = selectedEvent.managedServiceID else { return nil }
        return incidents.first {
            $0.managedServiceID == serviceID
                && ($0.summary?.relatedEventIDs.contains(selectedEvent.id) == true)
        }?.summary ?? incidents.first { $0.managedServiceID == serviceID }?.summary
    }

    private func profileName(for id: UUID?) -> String {
        guard let id else { return "—" }
        return profiles.first { $0.id == id }?.name ?? String(id.uuidString.prefix(8))
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
