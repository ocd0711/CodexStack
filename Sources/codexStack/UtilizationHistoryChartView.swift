import Charts
import SwiftUI

@MainActor
struct UtilizationHistoryChartView: View {
    private enum Layout {
        static let chartHeight: CGFloat = 110
        static let detailHeight: CGFloat = 16
        static let emptyStateHeight: CGFloat = chartHeight + detailHeight
        static let maxPoints = 30
        static let maxAxisLabels = 4
        static let barWidth: CGFloat = 6
    }

    private struct EntryPointAccumulator {
        let effectiveBoundaryDate: Date
        let displayBoundaryDate: Date
        let observedAt: Date
        let usedPercent: Double
        let hasObservedResetBoundary: Bool
    }

    private struct ResetBoundaryLattice {
        let referenceBoundaryDate: Date
        let windowInterval: TimeInterval
    }

    private struct Point: Identifiable {
        let id: Date
        let index: Int
        let date: Date
        let usedPercent: Double
        let isObserved: Bool
    }

    private struct SeriesModel {
        let points: [Point]
        let axisIndexes: [Double]
        let xDomain: ClosedRange<Double>?
        let pointsByID: [Date: Point]
        let pointsByIndex: [Int: Point]
    }

    let histories: [UtilizationSeriesHistory]

    @State private var selectedSeriesName: UtilizationSeriesName? =
        UtilizationSeriesName(rawValue: UserDefaults.standard.string(forKey: "utilization.selectedSeries") ?? "")
    @State private var selectedPointID: Date?

    private var visibleSeries: [UtilizationSeriesHistory] {
        histories
            .filter { !$0.entries.isEmpty }
            .sorted { $0.name.rawValue < $1.name.rawValue }
    }

    private var effectiveSeries: UtilizationSeriesHistory? {
        if let name = selectedSeriesName, let found = visibleSeries.first(where: { $0.name == name }) {
            return found
        }
        return visibleSeries.first
    }

    var body: some View {
        let series = visibleSeries
        let current = effectiveSeries
        let model = Self.makeModel(history: current)

        VStack(alignment: .leading, spacing: 8) {
            if series.count > 1 {
                Picker(
                    selection: Binding(
                        get: { current?.name ?? .session },
                        set: {
                            self.selectedSeriesName = $0
                            self.selectedPointID = nil
                            UserDefaults.standard.set($0.rawValue, forKey: "utilization.selectedSeries")
                        }
                    ),
                    label: EmptyView()
                ) {
                    ForEach(series, id: \.name) { s in
                        Text(s.name.title).tag(s.name)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            if model.points.isEmpty {
                ZStack {
                    Text("No \(current?.name.title.lowercased() ?? "utilization") history yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: Layout.emptyStateHeight)
            } else {
                utilizationChart(model: model)
                    .chartYAxis(.hidden)
                    .chartYScale(domain: 0...100)
                    .chartXAxis {
                        AxisMarks(values: model.axisIndexes) { value in
                            AxisGridLine().foregroundStyle(Color.clear)
                            AxisTick().foregroundStyle(Color.clear)
                            AxisValueLabel {
                                if let raw = value.as(Double.self) {
                                    let index = Int(raw.rounded())
                                    if let point = model.pointsByIndex[index] {
                                        let isTrailing = index == model.points.last?.index
                                            && model.points.count == Layout.maxPoints
                                        axisLabel(for: point, windowMinutes: current?.windowMinutes ?? 300, isTrailing: isTrailing)
                                    }
                                }
                            }
                        }
                    }
                    .chartLegend(.hidden)
                    .frame(height: Layout.chartHeight)
                    .chartOverlay { proxy in
                        GeometryReader { geo in
                            MouseLocationReader { location in
                                updateSelection(location: location, model: model, proxy: proxy, geo: geo)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                        }
                    }

                let activePoint = selectedPointID.flatMap { model.pointsByID[$0] } ?? model.points.last
                Text(detailLine(point: activePoint, windowMinutes: current?.windowMinutes ?? 300))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(height: Layout.detailHeight, alignment: .leading)
            }
        }
        .task(id: series.map(\.name.rawValue).joined()) {
            guard let first = series.first else { return }
            guard !series.contains(where: { $0.name == selectedSeriesName }) else { return }
            selectedSeriesName = first.name
            UserDefaults.standard.set(first.name.rawValue, forKey: "utilization.selectedSeries")
            selectedPointID = nil
        }
    }

    @ViewBuilder
    private func utilizationChart(model: SeriesModel) -> some View {
        if let domain = model.xDomain {
            Chart { chartContent(model: model) }.chartXScale(domain: domain)
        } else {
            Chart { chartContent(model: model) }
        }
    }

    @ChartContentBuilder
    private func chartContent(model: SeriesModel) -> some ChartContent {
        let trackColor = Color(nsColor: .separatorColor).opacity(0.4)
        ForEach(model.points) { point in
            BarMark(
                x: .value("Period", Double(point.index)),
                yStart: .value("Cap", 0),
                yEnd: .value("Cap", 100),
                width: .fixed(Layout.barWidth)
            )
            .foregroundStyle(trackColor)
            BarMark(
                x: .value("Period", Double(point.index)),
                yStart: .value("Used", 0),
                yEnd: .value("Used", point.usedPercent),
                width: .fixed(Layout.barWidth)
            )
            .foregroundStyle(Color.accentColor.opacity(point.isObserved ? 1 : 0.3))
        }
        if let selected = selectedPointID.flatMap({ model.pointsByID[$0] }) {
            RuleMark(x: .value("Sel", Double(selected.index)))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
    }

    @ViewBuilder
    private func axisLabel(for point: Point, windowMinutes: Int, isTrailing: Bool) -> some View {
        let label = Text(point.date.formatted(.dateTime.month(.abbreviated).day()))
            .font(.caption2)
            .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
        if isTrailing {
            label.frame(width: 48, alignment: .trailing).offset(x: -24)
        } else {
            label
        }
    }

    private func updateSelection(location: CGPoint?, model: SeriesModel, proxy: ChartProxy, geo: GeometryProxy) {
        guard let location else { if selectedPointID != nil { selectedPointID = nil }; return }
        let frame: CGRect
        if #available(macOS 14.0, *) {
            guard let anchor = proxy.plotFrame else { return }
            frame = geo[anchor]
        } else {
            frame = geo.frame(in: .local)
        }
        guard frame.contains(location) else { if selectedPointID != nil { selectedPointID = nil }; return }
        let xInPlot = location.x - frame.origin.x
        guard let xVal: Double = proxy.value(atX: xInPlot) else { return }
        let best = model.points.min(by: { abs(Double($0.index) - xVal) < abs(Double($1.index) - xVal) })
        if selectedPointID != best?.id { selectedPointID = best?.id }
    }

    private func detailLine(point: Point?, windowMinutes: Int) -> String {
        guard let point else { return "-" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
        formatter.dateFormat = windowMinutes <= 300 ? "MMM d, h:mm a" : "MMM d"
        let dateLabel = formatter.string(from: point.date)
        guard point.isObserved else { return "\(dateLabel): -" }
        let used = max(0, min(100, point.usedPercent))
        return "\(dateLabel): \(used.formatted(.number.precision(.fractionLength(0...1))))% used"
    }
}

// MARK: - Point calculation (ported from CodexBar)
extension UtilizationHistoryChartView {
    private static func makeModel(history: UtilizationSeriesHistory?) -> SeriesModel {
        guard let history else { return SeriesModel(points: [], axisIndexes: [], xDomain: nil, pointsByID: [:], pointsByIndex: [:]) }
        var points = seriesPoints(history: history, referenceDate: Date())
        if points.count > Layout.maxPoints { points = Array(points.suffix(Layout.maxPoints)) }
        points = points.enumerated().map { i, p in Point(id: p.id, index: i, date: p.date, usedPercent: p.usedPercent, isObserved: p.isObserved) }
        return SeriesModel(
            points: points,
            axisIndexes: axisIndexes(points: points, windowMinutes: history.windowMinutes),
            xDomain: points.isEmpty ? nil : (-0.5...(Double(Layout.maxPoints) - 0.5)),
            pointsByID: Dictionary(uniqueKeysWithValues: points.map { ($0.id, $0) }),
            pointsByIndex: Dictionary(uniqueKeysWithValues: points.map { ($0.index, $0) })
        )
    }

    private static func seriesPoints(history: UtilizationSeriesHistory, referenceDate: Date) -> [Point] {
        guard history.windowMinutes > 0 else { return [] }
        let windowInterval = Double(history.windowMinutes) * 60
        let lattice = resetBoundaryLattice(entries: history.entries, windowMinutes: history.windowMinutes)
        var strongest: [Date: EntryPointAccumulator] = [:]

        for entry in history.entries {
            let candidate = observedPointCandidate(for: entry, windowMinutes: history.windowMinutes, lattice: lattice)
            if let existing = strongest[candidate.effectiveBoundaryDate],
               !shouldPrefer(candidate, over: existing) { continue }
            strongest[candidate.effectiveBoundaryDate] = candidate
        }
        guard !strongest.isEmpty else { return [] }

        let sortedBoundaries = strongest.keys.sorted()
        var points: [Point] = []
        var prev: Date?

        for boundary in sortedBoundaries {
            if let prev {
                var cursor = prev.addingTimeInterval(windowInterval)
                while cursor < boundary {
                    points.append(Point(id: cursor, index: 0, date: cursor, usedPercent: 0, isObserved: false))
                    cursor = cursor.addingTimeInterval(windowInterval)
                }
            }
            if let bucket = strongest[boundary] {
                points.append(Point(id: bucket.effectiveBoundaryDate, index: 0, date: bucket.displayBoundaryDate, usedPercent: bucket.usedPercent, isObserved: true))
            }
            prev = boundary
        }

        if let last = sortedBoundaries.last {
            let current = currentPeriodBoundary(for: referenceDate, windowMinutes: history.windowMinutes, lattice: lattice)
            if current > last {
                var cursor = last.addingTimeInterval(windowInterval)
                while cursor <= current {
                    points.append(Point(id: cursor, index: 0, date: cursor, usedPercent: 0, isObserved: false))
                    cursor = cursor.addingTimeInterval(windowInterval)
                }
            }
        }
        return points
    }

    private static func observedPointCandidate(
        for entry: UtilizationHistoryEntry,
        windowMinutes: Int,
        lattice: ResetBoundaryLattice?
    ) -> EntryPointAccumulator {
        let raw = entry.resetsAt.map(normalizedDate)
        let effective = effectiveBoundary(for: entry, windowMinutes: windowMinutes, rawReset: raw, lattice: lattice)
        return EntryPointAccumulator(
            effectiveBoundaryDate: effective,
            displayBoundaryDate: raw ?? effective,
            observedAt: entry.capturedAt,
            usedPercent: max(0, min(100, entry.usedPercent)),
            hasObservedResetBoundary: raw != nil)
    }

    private static func effectiveBoundary(
        for entry: UtilizationHistoryEntry,
        windowMinutes: Int,
        rawReset: Date?,
        lattice: ResetBoundaryLattice?
    ) -> Date {
        if let raw = rawReset {
            return lattice.map { closestBoundary(to: raw, lattice: $0) } ?? raw
        }
        if let lattice { return periodBoundary(containing: entry.capturedAt, lattice: lattice) }
        return syntheticBoundary(for: entry.capturedAt, windowMinutes: windowMinutes)
    }

    private static func resetBoundaryLattice(entries: [UtilizationHistoryEntry], windowMinutes: Int) -> ResetBoundaryLattice? {
        guard let latest = entries.compactMap(\.resetsAt).map(normalizedDate).max() else { return nil }
        return ResetBoundaryLattice(referenceBoundaryDate: latest, windowInterval: Double(windowMinutes) * 60)
    }

    private static func normalizedDate(_ d: Date) -> Date { Date(timeIntervalSince1970: floor(d.timeIntervalSince1970)) }

    private static func closestBoundary(to raw: Date, lattice: ResetBoundaryLattice) -> Date {
        let offset = raw.timeIntervalSince(lattice.referenceBoundaryDate)
        let n = (offset / lattice.windowInterval).rounded()
        return lattice.referenceBoundaryDate.addingTimeInterval(n * lattice.windowInterval)
    }

    private static func periodBoundary(containing date: Date, lattice: ResetBoundaryLattice) -> Date {
        let offset = date.timeIntervalSince(lattice.referenceBoundaryDate)
        let n = ceil(offset / lattice.windowInterval)
        return lattice.referenceBoundaryDate.addingTimeInterval(n * lattice.windowInterval)
    }

    private static func syntheticBoundary(for date: Date, windowMinutes: Int) -> Date {
        let bucket = Double(windowMinutes) * 60
        let n = floor(date.timeIntervalSince1970 / bucket)
        return Date(timeIntervalSince1970: (n + 1) * bucket)
    }

    private static func currentPeriodBoundary(for date: Date, windowMinutes: Int, lattice: ResetBoundaryLattice?) -> Date {
        lattice.map { periodBoundary(containing: date, lattice: $0) } ?? syntheticBoundary(for: date, windowMinutes: windowMinutes)
    }

    private static func shouldPrefer(_ c: EntryPointAccumulator, over e: EntryPointAccumulator) -> Bool {
        if c.usedPercent != e.usedPercent { return c.usedPercent > e.usedPercent }
        if c.hasObservedResetBoundary != e.hasObservedResetBoundary { return c.hasObservedResetBoundary }
        if c.displayBoundaryDate != e.displayBoundaryDate { return c.displayBoundaryDate > e.displayBoundaryDate }
        return c.observedAt >= e.observedAt
    }

    private static func axisIndexes(points: [Point], windowMinutes: Int) -> [Double] {
        guard !points.isEmpty else { return [] }
        let occupied = Double(points.count) / Double(Layout.maxPoints)
        let budget = max(1, min(Layout.maxAxisLabels, Int(ceil(Double(Layout.maxAxisLabels) * occupied))))

        var candidates: [Int]
        if windowMinutes <= 300 {
            let cal = Calendar.current
            var prev = points[0]
            candidates = [prev.index]
            for p in points.dropFirst() {
                if !cal.isDate(p.date, inSameDayAs: prev.date) { candidates.append(p.index) }
                prev = p
            }
        } else {
            candidates = points.map(\.index)
        }
        guard !candidates.isEmpty else { return [] }
        if budget == 1 { return [Double(candidates[0])] }

        let step = Double(candidates.count - 1) / Double(budget - 1)
        var selected = (0..<budget).map { candidates[Int((Double($0) * step).rounded())] }
        selected = Array(NSOrderedSet(array: selected)) as? [Int] ?? selected

        let trailingCutoff = points[0].index + Int(floor(Double(points.count) * 0.8))
        if selected.count > 1, let last = selected.last, last >= trailingCutoff { selected.removeLast() }
        if points.count == Layout.maxPoints, let lastIdx = points.last?.index, !selected.contains(lastIdx) { selected.append(lastIdx) }

        return (Array(NSOrderedSet(array: selected)) as? [Int] ?? selected).map(Double.init)
    }
}
