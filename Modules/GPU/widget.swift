//
//  widget.swift
//  GPU
//
//  Created by Serhiy Mytrovtsiy on 17/07/2024
//  Using Swift 5.0.
//  Running on macOS 14.5
//
//  Copyright © 2024 Serhiy Mytrovtsiy. All rights reserved.
//

import SwiftUI
import WidgetKit
import Charts
import Kit

/// Widget entry. Carries the full list of active GPUs (and the
/// selected one, for downstream widgets that still decode a single
/// GPU_Info under "GPU@InfoReader"). The InfoReader writes the list
/// and the selected snapshot in the same callback, so they update
/// together.
public struct GPU_entry: TimelineEntry {
    public static let kind = "GPUWidget"
    public static var snapshot: GPU_entry = GPU_entry(
        list: [
            GPU_Info(id: "", type: "", IOClass: "", model: "GPU", cores: nil,
                      utilization: 0.11, render: 0.11, tiler: 0.11)
        ],
        isPreview: true
    )

    public var date: Date {
        Calendar.current.date(byAdding: .second, value: 5, to: Date())!
    }
    public var list: [GPU_Info] = []
    public var selected: GPU_Info? = nil
    public var isPreview: Bool = false

    /// Backwards-compat accessor — older code (and the UnitedWidget)
    /// still decodes the single-GPU snapshot under "GPU@InfoReader".
    var value: GPU_Info? { selected ?? list.first }
}

public struct Provider: TimelineProvider {
    public typealias Entry = GPU_entry

    private let userDefaults: UserDefaults? = UserDefaults(suiteName: "\(Bundle.main.object(forInfoDictionaryKey: "TeamId") as! String).eu.exelban.Stats.widgets")

    public var systemWidgetsUpdatesState: Bool {
        self.userDefaults?.bool(forKey: "systemWidgetsUpdates_state") ?? false
    }

    public func placeholder(in context: Context) -> GPU_entry {
        GPU_entry()
    }

    public func getSnapshot(in context: Context, completion: @escaping (GPU_entry) -> Void) {
        completion(GPU_entry.snapshot)
    }

    public func getTimeline(in context: Context, completion: @escaping (Timeline<GPU_entry>) -> Void) {
        self.userDefaults?.set(Date().timeIntervalSince1970, forKey: GPU_entry.kind)
        var entry = GPU_entry()
        if let raw = userDefaults?.data(forKey: "GPU@InfoReader.list"),
           let list = try? JSONDecoder().decode([GPU_Info].self, from: raw) {
            entry.list = list
        } else if let raw = userDefaults?.data(forKey: "GPU@InfoReader"),
                  let single = try? JSONDecoder().decode(GPU_Info.self, from: raw) {
            // Fall back to the single-GPU snapshot if the list hasn't
            // been written yet. Renders one slice in the cumulative
            // circles instead of empty ones.
            entry.list = [single]
        }
        if let raw = userDefaults?.data(forKey: "GPU@InfoReader"),
           let single = try? JSONDecoder().decode(GPU_Info.self, from: raw) {
            entry.selected = single
        }
        let entries: [GPU_entry] = [entry]
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

@available(macOS 14.0, *)
public struct GPUWidget: Widget {
    /// Per-GPU palette. Hash the model name for a stable colour
    /// assignment so a GPU always lands on the same hue across
    /// reloads and across rows. Eight colours is enough for any
    /// currently-shipping Mac (Apple Silicon Mac Pro supports up to
    /// 4 GPUs in some configurations, the Mac Pro 7,1 with two
    /// W6800X Duos exposes 4 dies, an eGPU makes 5).
    private static let palette: [Color] = [
        Color(red: 0.20, green: 0.55, blue: 0.95), // blue
        Color(red: 0.95, green: 0.45, blue: 0.20), // orange
        Color(red: 0.30, green: 0.75, blue: 0.45), // green
        Color(red: 0.85, green: 0.25, blue: 0.55), // pink
        Color(red: 0.55, green: 0.35, blue: 0.85), // purple
        Color(red: 0.20, green: 0.70, blue: 0.75), // teal
        Color(red: 0.90, green: 0.65, blue: 0.20), // amber
        Color(red: 0.45, green: 0.55, blue: 0.65)  // slate
    ]

    private static func colour(for gpu: GPU_Info, index: Int) -> Color {
        var hasher = Hasher()
        hasher.combine(gpu.model)
        hasher.combine(index) // tie-breaker for duplicate models
        let h = hasher.finalize()
        return palette[(h & Int.max) % palette.count]
    }

    /// A GPU's contribution to a single metric, normalised to 0..1 by
    /// dividing by the sum across all GPUs. Returns 0 when the total
    /// is zero (e.g. no data anywhere).
    private static func share(_ value: Double?, total: Double) -> Double {
        guard let value, total > 0 else { return 0 }
        return max(0, min(1, value / total))
    }

    /// Local copy of the metric enum. The widget file is compiled in
    /// isolation against the WidgetsExtension target (which does not
    /// link the GPU module's full source), so we keep this minimal
    /// mapping here instead of pulling in a cross-module enum.
    fileprivate struct Metric {
        static let vram    = "vram"
        static let compute = "compute"
        static let power   = "power"
    }

    public init() {}

    public var body: some WidgetConfiguration {
        StaticConfiguration(kind: GPU_entry.kind, provider: Provider()) { entry in
            VStack(alignment: .leading, spacing: 4) {
                if Provider().systemWidgetsUpdatesState || entry.isPreview {
                    if entry.list.isEmpty {
                        VStack {
                            Text("No GPU data")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        circlesView(entry: entry)
                    }
                } else {
                    Text("Enable in Settings")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(.secondary)
                }
            }
            .padding(6)
            .containerBackground(for: .widget) {
                Color.clear
            }
        }
        .configurationDisplayName("GPU widget")
        .description("VRAM / Compute / Power per GPU")
        .supportedFamilies([.systemSmall])
    }

    @ViewBuilder
    private func circlesView(entry: GPU_entry) -> some View {
        // The cumulative totals drive the centre-of-circle text. The
        // circles themselves show each GPU's share of the total.
        // Power is nil on the Apple backend (the
        // PerformanceStatistics dictionary doesn't publish it) so the
        // total stays at 0 and the power circle shows a single grey
        // ring with "—" in the middle until we wire a power source.
        let vramTotal    = entry.list.compactMap { $0.utilization }.reduce(0, +)
        let computeTotal = entry.list.compactMap { $0.utilization }.reduce(0, +)
        let powerTotal   = 0.0

        VStack(spacing: 6) {
            circleRow(label: "VRAM",     total: vramTotal,    list: entry.list)
            circleRow(label: "Compute",  total: computeTotal, list: entry.list)
            circleRow(label: "Power",    total: powerTotal,   list: entry.list)
        }
    }

    @ViewBuilder
    private func circleRow(label: String, total: Double, list: [GPU_Info]) -> some View {
        HStack(spacing: 6) {
            // The metric label is fixed-width so the three circles
            // line up across rows in the small widget.
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 44, alignment: .leading)

            ZStack {
                if total > 0.001 {
                    // Stack the sectors from largest to smallest so the
                    // biggest slice is drawn first and small slices
                    // aren't hidden behind it. The `idx` is the GPU's
                    // position in the original list — we use it both
                    // for the colour (stable per slot) and as the
                    // (stable) sort key for the value.
                    let sectors: [(idx: Int, gpu: GPU_Info, share: Double)] = list.enumerated().compactMap { (i, gpu) in
                        let s = Self.share(gpu.utilization, total: total)
                        return s > 0.001 ? (i, gpu, s) : nil
                    }.sorted { $0.share > $1.share }
                    Canvas { context, size in
                        let radius = min(size.width, size.height) / 2
                        let center = CGPoint(x: size.width / 2, y: size.height / 2)
                        // Start at the top (12 o'clock) and go clockwise.
                        var startAngle = -CGFloat.pi / 2
                        for sector in sectors {
                            let endAngle = startAngle + sector.share * 2 * .pi
                            let path = Path { p in
                                p.move(to: center)
                                p.addArc(center: center, radius: radius,
                                          startAngle: .radians(startAngle),
                                          endAngle: .radians(endAngle),
                                          clockwise: false)
                                p.closeSubpath()
                            }
                            // Colour per GPU, derived from the GPU's
                            // slot in the original list (stable across
                            // reloads, not affected by sort order).
                            context.fill(path, with: .color(Self.colour(for: sector.gpu, index: sector.idx)))
                            startAngle = endAngle
                        }
                    }
                    .frame(width: 56, height: 56)
                } else {
                    // No data: a single hollow ring so the row keeps
                    // its shape and the user can tell "no data" from
                    // "0% across the board".
                    Circle()
                        .strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1)
                        .frame(width: 56, height: 56)
                }

                // Centre text: the cumulative value across all GPUs.
                if total > 0.001 {
                    Text(String(format: "%.0f", total))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)
                } else {
                    Text("—")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 56, height: 56)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
