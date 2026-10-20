import SwiftUI
import AppKit
import Combine

// MARK: - Compatibility matrix
// Static cells, one hover state object per table, one tracking NSView per table.
// Hovering only updates local presentation, never probes conversion routes.

enum MatrixCell: Equatable {
    case available
    case sameFormat   // diagonal, converting to itself is a no-op
    case unsupported
}

struct MatrixTableData: Equatable {
    let name: String
    let icon: String
    let inputs: [String]
    let outputs: [String]
    let cells: [[MatrixCell]]   // [input][output]

    /// XLS is Excel 2003 SpreadsheetML XML only (see LegacySpreadsheet). Keep the qualifier
    /// until the shared registry can name a binary BIFF dependency explicitly.
    private static let allOrder: [String: Int] = Dictionary(
        FormatCatalog.allFormats.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
    static func order(_ f: String) -> Int { allOrder[f] ?? 999 }
    static func label(_ format: String) -> String { format == "XLS" ? "XLS XML" : format }

    /// Pure function of the cached capability snapshot. All category inputs stay as rows.
    static func build(name: String, icon: String, formats: [String], outputsOf: (String) -> [String]) -> MatrixTableData {
        let routes = formats.map { Set(outputsOf($0)) }
        let outs = Array(routes.reduce(into: Set<String>()) { $0.formUnion($1) })
            .sorted { order($0) < order($1) }
        let cells = zip(formats, routes).map { input, supported in
            outs.map { out -> MatrixCell in
                if out == input { return .sameFormat }
                return supported.contains(out) ? .available : .unsupported
            }
        }
        return MatrixTableData(name: name, icon: icon, inputs: formats, outputs: outs, cells: cells)
    }
}

enum MatrixMetrics {
    static let labelWidth: CGFloat = 58
    static let headerHeight: CGFloat = 76
    static let rowHeight: CGFloat = 20
    static let spacing: CGFloat = 2
    static func cellWidth(total: CGFloat, columns: Int) -> CGFloat {
        max(1, (total - labelWidth - spacing * CGFloat(columns)) / CGFloat(max(1, columns)))
    }
    static func column(atX x: CGFloat, cellWidth: CGFloat, columns: Int) -> Int? {
        let rel = x - labelWidth - spacing
        guard rel >= 0 else { return nil }
        let i = Int(rel / (cellWidth + spacing))
        return i < columns ? i : nil
    }
    static func row(atY y: CGFloat, rows: Int) -> Int? {
        let rel = y - headerHeight
        guard rel >= 0 else { return nil }
        let i = Int(rel / rowHeight)
        return i < rows ? i : nil
    }
}

/// Owned per table by CompatibilityViewModel. Published values only change when the cell under the pointer changes.
@MainActor
final class MatrixHoverState: ObservableObject {
    @Published private(set) var row: Int?
    @Published private(set) var column: Int?
    func set(row: Int?, column: Int?) {
        if self.row != row { self.row = row }
        if self.column != column { self.column = column }
    }
}

/// Persistent. Tables and hover states are built once per capability snapshot, never inside a body.
@MainActor
final class CompatibilityViewModel: ObservableObject {
    static let shared = CompatibilityViewModel()
    static let sections: [(String, String)] = [
        ("Images", "photo"), ("Documents", "doc.text"), ("Presentations", "rectangle.on.rectangle"), ("Spreadsheets", "tablecells"),
        ("Audio", "waveform"), ("Video", "film"), ("Archives", "archivebox"), ("Subtitles", "captions.bubble")
    ]

    /// Rows come only from the Formats-tab settings groups (GIF under Video, Presentations separate).
    /// Never filtered by route count, so input-only formats like KEY, NUMBERS, 7Z still appear.
    static func rows(for name: String) -> [String] {
        FormatCatalog.settingsGroups.first(where: { $0.name == name })?.formats ?? []
    }
    @Published private(set) var tables: [MatrixTableData] = []
    private(set) var hover: [String: MatrixHoverState] = [:]
    private var cancellable: AnyCancellable?
    private var builtFrom: [String: [String]]?

    private init() {
        let caps = FormatCapabilities.shared
        cancellable = caps.$outputsByInput.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.rebuild() }
        rebuild()
    }

    func rebuild() {
        let caps = FormatCapabilities.shared
        guard !caps.isLoading, builtFrom != caps.outputsByInput else { return }
        builtFrom = caps.outputsByInput
        tables = Self.sections.map { name, icon in
            MatrixTableData.build(name: name, icon: icon, formats: Self.rows(for: name)) { caps.outputs(of: $0) }
        }
        for t in tables where hover[t.name] == nil { hover[t.name] = MatrixHoverState() }
    }
    func clearHover() {
        for state in hover.values { state.set(row: nil, column: nil) }
    }
    func hoverState(for name: String) -> MatrixHoverState { hover[name] ?? MatrixHoverState() }
}

// MARK: Views

struct CompatibilityMatrixView: View {
    let table: MatrixTableData
    let hover: MatrixHoverState
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(table.name, systemImage: table.icon).font(.system(size: 13, weight: .semibold))
            if table.outputs.isEmpty {
                Text("No conversions available from these formats on this Mac right now.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                GeometryReader { geometry in
                    let cw = MatrixMetrics.cellWidth(total: geometry.size.width, columns: table.outputs.count)
                    ZStack(alignment: .topLeading) {
                        MatrixHighlightOverlay(table: table, hover: hover, cellWidth: cw)
                        MatrixStaticGrid(table: table, hover: hover, cellWidth: cw)
                        MatrixHoverTracker(hover: hover, rows: table.inputs.count, columns: table.outputs.count, cellWidth: cw)
                    }
                }
                .frame(height: MatrixMetrics.headerHeight + CGFloat(table.inputs.count) * MatrixMetrics.rowHeight)
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onDisappear { hover.set(row: nil, column: nil) }
    }
}

/// Uses the same labels for normal and highlighted states, with identical layout.
struct MatrixStaticGrid: View {
    let table: MatrixTableData
    @ObservedObject var hover: MatrixHoverState
    let cellWidth: CGFloat
    var body: some View {
        Grid(horizontalSpacing: MatrixMetrics.spacing, verticalSpacing: 0) {
            GridRow {
                Image(systemName: "arrow.turn.right.down").foregroundStyle(.secondary)
                    .font(.system(size: 10))
                    .frame(width: MatrixMetrics.labelWidth, height: MatrixMetrics.headerHeight, alignment: .bottomLeading)
                ForEach(Array(table.outputs.enumerated()), id: \.offset) { c, output in
                    Text(MatrixTableData.label(output)).font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(hover.column == c ? Color.margherita : Color.secondary).fixedSize()
                        .rotationEffect(.degrees(-90))
                        .frame(width: cellWidth, height: MatrixMetrics.headerHeight)
                        .accessibilityLabel("Output " + output)
                }
            }
            ForEach(Array(table.inputs.enumerated()), id: \.offset) { r, input in
                GridRow {
                    Text(MatrixTableData.label(input)).font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(hover.row == r ? Color.margherita : Color.secondary).lineLimit(1).minimumScaleFactor(0.7)
                        .frame(width: MatrixMetrics.labelWidth, height: MatrixMetrics.rowHeight, alignment: .leading)
                    ForEach(Array(table.outputs.enumerated()), id: \.offset) { c, output in
                        cell(table.cells[r][c], input: input, output: output)
                            .frame(width: cellWidth, height: MatrixMetrics.rowHeight)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
    @ViewBuilder private func cell(_ kind: MatrixCell, input: String, output: String) -> some View {
        switch kind {
        case .available:
            Image(systemName: "checkmark").font(.system(size: 8, weight: .semibold)).foregroundStyle(Color.basil)
                .accessibilityLabel(input + " to " + output + " available")
        case .sameFormat:
            Image(systemName: "equal").font(.system(size: 7, weight: .medium)).foregroundStyle(.quaternary)
                .accessibilityLabel(input + " to " + output + " same format, nothing to convert")
        case .unsupported:
            Text("\u{2014}").font(.system(size: 8)).foregroundStyle(.tertiary)
                .accessibilityLabel(input + " to " + output + " unavailable")
        }
    }
}

/// Background-only bands. Header text is rendered exactly once by the grid.
struct MatrixHighlightOverlay: View {
    let table: MatrixTableData
    @ObservedObject var hover: MatrixHoverState
    let cellWidth: CGFloat
    var body: some View {
        let m = MatrixMetrics.self
        let width = m.labelWidth + CGFloat(table.outputs.count) * (cellWidth + m.spacing)
        ZStack(alignment: .topLeading) {
            if let r = hover.row {
                RoundedRectangle(cornerRadius: 4).fill(Color.margherita.opacity(0.07))
                    .frame(width: width, height: m.rowHeight)
                    .offset(x: 0, y: m.headerHeight + CGFloat(r) * m.rowHeight)
            }
            if let c = hover.column {
                RoundedRectangle(cornerRadius: 4).fill(Color.margherita.opacity(0.07))
                    .frame(width: cellWidth, height: m.headerHeight + CGFloat(table.inputs.count) * m.rowHeight)
                    .offset(x: m.labelWidth + m.spacing + CGFloat(c) * (cellWidth + m.spacing), y: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

/// One NSTrackingArea per table. Converts the pointer to a row and column with arithmetic only.
struct MatrixHoverTracker: NSViewRepresentable {
    let hover: MatrixHoverState
    let rows: Int
    let columns: Int
    let cellWidth: CGFloat
    func makeNSView(context: Context) -> TrackerView {
        let v = TrackerView(); apply(v); return v
    }
    func updateNSView(_ nsView: TrackerView, context: Context) { apply(nsView) }
    static func dismantleNSView(_ nsView: TrackerView, coordinator: ()) {
        nsView.hover?.set(row: nil, column: nil)
        nsView.stopObservingScroll()
        nsView.hover = nil
    }
    private func apply(_ v: TrackerView) {
        v.hover = hover; v.rows = rows; v.columns = columns; v.cellWidth = cellWidth
    }

    final class TrackerView: NSView {
        weak var hover: MatrixHoverState?
        var rows = 0, columns = 0
        var cellWidth: CGFloat = 1
        private weak var observedClipView: NSClipView?
        private var scrollObserver: NSObjectProtocol?
        override var isFlipped: Bool { true }
        func stopObservingScroll() {
            if let observer = scrollObserver { NotificationCenter.default.removeObserver(observer) }
            scrollObserver = nil
            observedClipView = nil
        }
        private func observeScroll() {
            let clip = enclosingScrollView?.contentView
            guard clip !== observedClipView else { return }
            stopObservingScroll()
            guard let clip = clip else { return }
            observedClipView = clip
            clip.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self] _ in self?.updateFromPointer() }
        }
        deinit { if let observer = scrollObserver { NotificationCenter.default.removeObserver(observer) } }
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            observeScroll()
        }
        private func updateFromPointer() {
            guard let window = window, window.isKeyWindow, !isHiddenOrHasHiddenAncestor else {
                hover?.set(row: nil, column: nil)
                return
            }
            update(at: window.mouseLocationOutsideOfEventStream)
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            observeScroll()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(rect: bounds,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
            updateFromPointer()
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observeScroll()
            hover?.set(row: nil, column: nil)
        }
        override func mouseMoved(with event: NSEvent) { update(event) }
        override func mouseEntered(with event: NSEvent) { update(event) }
        override func mouseExited(with event: NSEvent) { hover?.set(row: nil, column: nil) }
        // Let clicks and scrolling pass through to the page.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        private func update(_ event: NSEvent) {
            update(at: event.locationInWindow)
        }
        private func update(at location: NSPoint) {
            let p = convert(location, from: nil)
            guard bounds.contains(p) else {
                hover?.set(row: nil, column: nil)
                return
            }
            guard visibleRect.contains(p) else {
                hover?.set(row: nil, column: nil)
                return
            }
            let r = MatrixMetrics.row(atY: p.y, rows: rows)
            let c = MatrixMetrics.column(atX: p.x, cellWidth: cellWidth, columns: columns)
            // Pointer in the header strip or label column still highlights its own axis.
            hover?.set(row: r, column: c)
        }
    }
}
