//
//  popup.swift
//  GPU
//
//  Created by Serhiy Mytrovtsiy on 17/08/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit

internal class Popup: PopupWrapper {
    private let dashboardHeight: CGFloat = 90
    private let chartHeight: CGFloat = 90 + Constants.Popup.separatorHeight
    // The details section shows up to 13 rows (common + discrete + iGPU)
    // but the rendering code hides irrelevant ones. Pick a height that
    // fits the largest case; the stack view's content compression and
    // hidden row flags keep the smaller cases compact.
    private let detailsHeight: CGFloat = (22*13) + Constants.Popup.separatorHeight

    private let loadCache = PopupCache<GPU_Info>()

    private var usageCircle: PieChartView? = nil
    private var renderCircle: PieChartView? = nil
    private var tilerCircle: PieChartView? = nil

    private var chart: LineChartView? = nil
    private var lineChartHistory: Int = 180
    private var lineChartScale: Scale = .none
    private var lineChartFixedScale: Double = 1

    // Single-GPU details. The Apple-Silicon-specific fields (Cores,
    // Renderer, Tiler, ANE, FPS) are hidden on discrete AMD/NVIDIA
    // cards where the values are meaningless. The discrete-specific
    // fields (Slot, Power, VRAM) are hidden on iGPUs.
    private var modelField: NSTextField? = nil
    private var coresField: NSTextField? = nil
    private var utilizationField: NSTextField? = nil
    private var renderField: NSTextField? = nil
    private var tilerField: NSTextField? = nil
    private var aneField: NSTextField? = nil
    private var fpsField: NSTextField? = nil
    private var temperatureField: NSTextField? = nil
    private var fanSpeedField: NSTextField? = nil
    private var clockField: NSTextField? = nil
    private var slotField: NSTextField? = nil
    private var powerField: NSTextField? = nil
    private var vramField: NSTextField? = nil

    // Per-GPU list rendered below the single-GPU details. Built lazily on the
    // first allGPUsCallback and re-used across updates; one row per GPU. The
    // container itself is always present so recalculateHeight() stays stable.
    private var perGPUContainer: NSStackView? = nil
    private var perGPURows: [(id: String, label: NSTextField, value: NSTextField)] = []
    
    public init(_ module: ModuleType) {
        super.init(module, frame: NSRect(x: 0, y: 0, width: Constants.Popup.width, height: 0))

        self.orientation = .vertical
        self.distribution = .fill
        self.spacing = 0

        self.addArrangedSubview(self.initDashboard())
        self.addArrangedSubview(self.initChart())
        self.addArrangedSubview(self.initDetails())
        self.addArrangedSubview(self.initPerGPU())

        self.recalculateHeight()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override func updateLayer() {
        self.chart?.display()
    }
    
    public override func appear() {
        self.replay(self.loadCache, render: self.renderLoad)
    }
    
    private func recalculateHeight() {
        let h = self.arrangedSubviews.map({ $0.bounds.height + self.spacing }).reduce(0, +) - self.spacing
        if self.frame.size.height != h {
            self.setFrameSize(NSSize(width: self.frame.width, height: h))
            self.sizeCallback?(self.frame.size)
        }
    }
    
    private func initDashboard() -> NSView {
        let view: NSView = NSView(frame: NSRect(x: 0, y: 0, width: self.frame.width, height: self.dashboardHeight))
        view.heightAnchor.constraint(equalToConstant: view.bounds.height).isActive = true
        
        let usageSize = self.dashboardHeight-20
        let usageX = (view.frame.width - usageSize)/2
        
        let usage = NSView(frame: NSRect(x: usageX, y: (view.frame.height - usageSize)/2, width: usageSize, height: usageSize))
        let render = NSView(frame: NSRect(x: (usageX - 50)/2, y: (view.frame.height - 50)/2 - 3, width: 50, height: 50))
        let tiler = NSView(frame: NSRect(x: (usageX+usageSize) + (usageX - 50)/2, y: 0, width: 50, height: self.dashboardHeight))
        
        self.usageCircle = PieChartView(frame: NSRect(x: 0, y: 0, width: usage.frame.width, height: usage.frame.height), drawValue: true)
        self.usageCircle!.toolTip = localizedString("Utilization")
        usage.addSubview(self.usageCircle!)
        
        self.renderCircle = PieChartView(frame: NSRect(x: 0, y: 0, width: render.frame.width, height: render.frame.height), drawValue: true)
        self.renderCircle!.toolTip = localizedString("Renderer utilization")
        render.addSubview(self.renderCircle!)
        
        self.tilerCircle = PieChartView(frame: NSRect(x: 0, y: 0, width: tiler.frame.width, height: tiler.frame.height), drawValue: true)
        self.tilerCircle!.toolTip = localizedString("Tiler utilization")
        tiler.addSubview(self.tilerCircle!)
        
        view.addSubview(render)
        view.addSubview(usage)
        view.addSubview(tiler)
        
        return view
    }
    
    private func initChart() -> NSView  {
        let view: NSView = NSView(frame: NSRect(x: 0, y: 0, width: self.frame.width, height: self.chartHeight))
        view.heightAnchor.constraint(equalToConstant: 90 + Constants.Popup.separatorHeight).isActive = true
        let separator = separatorView(localizedString("Usage history"), origin: NSPoint(x: 0, y: self.chartHeight-Constants.Popup.separatorHeight), width: self.frame.width)
        let container: NSView = NSView(frame: NSRect(x: 0, y: 0, width: self.frame.width, height: separator.frame.origin.y))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.lightGray.withAlphaComponent(0.1).cgColor
        container.layer?.cornerRadius = Constants.Popup.radius
        
        let chartFrame = NSRect(x: 1, y: 0, width: view.frame.width - 2, height: container.frame.height)
        self.chart = LineChartView(frame: chartFrame, num: self.lineChartHistory, scale: self.lineChartScale, fixedScale: self.lineChartFixedScale)
        container.addSubview(self.chart!)
        
        view.addSubview(separator)
        view.addSubview(container)
        
        return view
    }
    
    private func initDetails() -> NSView  {
        let view: NSView = NSView(frame: NSRect(x: 0, y: 0, width: self.frame.width, height: self.detailsHeight))
        let separator = separatorView(localizedString("Details"), origin: NSPoint(x: 0, y: self.detailsHeight-Constants.Popup.separatorHeight), width: self.frame.width)
        let container: NSStackView = NSStackView(frame: NSRect(x: 0, y: 0, width: view.frame.width, height: separator.frame.origin.y))
        container.orientation = .vertical
        container.spacing = 0

        // Common rows for every GPU. Model + Utilisation are the
        // baseline; Temperature and Clocks come from the
        // AMDPerformanceStatistics dictionary on discrete cards and
        // from the IOAccelerator's internal counters on iGPUs.
        self.modelField = popupRow(container, title: "\(localizedString("Model")):", value: "").1
        self.utilizationField = popupRow(container, title: "\(localizedString("Utilization")):", value: "").1

        // Discrete-specific rows. The user's feedback on a Mac Pro 7,1
        // was that the Apple-Silicon engine counters (Cores, Renderer,
        // Tiler, ANE) are meaningless on a discrete AMD card and
        // should not be shown. The chassis slot, power draw and used
        // VRAM are the three numbers that actually vary across the
        // five cards they have.
        self.slotField = popupRow(container, title: "\(localizedString("Slot")):", value: "—").1
        self.powerField = popupRow(container, title: "\(localizedString("Power")):", value: "—").1
        self.vramField = popupRow(container, title: "\(localizedString("VRAM used")):", value: "—").1
        self.temperatureField = popupRow(container, title: "\(localizedString("Temperature")):", value: "—").1
        self.clockField = popupRow(container, title: "\(localizedString("Clocks")):", value: "—").1
        // Fan: chassis fan, not per-GPU on a Mac Pro, but the AMD
        // driver publishes a per-die fan percentage. Render it when
        // we have a value; show "—" otherwise.
        self.fanSpeedField = popupRow(container, title: "\(localizedString("Fan speed")):", value: "—").1

        // Apple-Silicon-only rows. The IOAccelerator PerformanceStatistics
        // dictionary doesn't publish these for AMD/NVIDIA discrete
        // cards; hide them when the selected GPU is discrete to avoid
        // empty or misleading rows.
        self.coresField = popupRow(container, title: "\(localizedString("Cores")):", value: localizedString("Unknown")).1
        self.renderField = popupRow(container, title: "\(localizedString("Renderer utilization")):", value: "—").1
        self.tilerField = popupRow(container, title: "\(localizedString("Tiler utilization")):", value: "—").1
        self.aneField = popupRow(container, title: "\(localizedString("ANE utilization")):", value: "—").1
        self.fpsField = popupRow(container, title: "\(localizedString("FPS")):", value: "—").1

        view.addSubview(separator)
        view.addSubview(container)

        return view
    }

    /// Builds the per-GPU "every card" section that lives below the single-GPU
    /// details. The section is its own arranged subview of the popup so its
    /// height participates in `recalculateHeight()`; when only one GPU is
    /// present it's hidden entirely so single-GPU systems see no layout change.
    private func initPerGPU() -> NSView {
        let view: NSView = NSView(frame: NSRect(x: 0, y: 0, width: self.frame.width, height: 0))
        let separator = separatorView(localizedString("Per-GPU"), origin: NSPoint(x: 0, y: 0), width: self.frame.width)
        self.perGPUContainer = NSStackView(frame: NSRect(x: 0, y: 0, width: self.frame.width, height: 0))
        self.perGPUContainer?.orientation = .vertical
        self.perGPUContainer?.spacing = 0
        self.perGPUContainer?.identifier = NSUserInterfaceItemIdentifier("perGPUContainer")

        view.addSubview(separator)
        view.addSubview(self.perGPUContainer!)
        view.isHidden = true
        return view
    }

    // MARK: - Per-GPU list

    /// Rebuilds the "Per-GPU" rows for every active GPU. Called from
    /// `Main.infoCallback` whenever the full GPU list updates so multi-GPU
    /// machines (e.g. a Mac Pro with a W6800X Duo) show every GPU instead of
    /// only the selected one. Single-GPU systems are unaffected: the single
    /// selected GPU already covers everything, so we just hide the section.
    ///
    /// All AppKit mutations happen on the main queue. `Reader.callback`
    /// dispatches on a background queue (see `reader.swift:start`), and the
    /// first version of this method was crashing with NSInternalInconsistencyException
    /// at -[NSView removeFromSuperview] because the stack view's auto-layout
    /// pass was already in flight on the main thread.
    public func allGPUsCallback(_ gpus: [GPU_Info]) {
        if Thread.isMainThread {
            self.allGPUsCallbackImpl(gpus)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.allGPUsCallbackImpl(gpus)
            }
        }
    }

    private func allGPUsCallbackImpl(_ gpus: [GPU_Info]) {
        guard let container = self.perGPUContainer else { return }
        guard let perGPUView = container.superview else { return }

        // NSStackView arranged subviews must be removed with removeArrangedSubview
        // (followed by removeFromSuperview if the view is no longer wanted)
        // rather than removeFromSuperview alone — the latter leaves the stack
        // view with stale constraints and trips an NSInternalInconsistencyException
        // on the next layout pass.
        let existing = container.arrangedSubviews
        for v in existing {
            container.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        self.perGPURows.removeAll()

        let active = gpus.filter { $0.state && $0.utilization != nil }
            .sorted { ($0.utilization ?? 0) > ($1.utilization ?? 0) }

        // Nothing to render on a single-GPU host, or when every GPU is asleep.
        guard active.count > 1 else {
            perGPUView.isHidden = true
            self.recalculateHeight()
            return
        }
        perGPUView.isHidden = false

        for gpu in active {
            let row = popupRow(container,
                               title: "\(gpu.model):",
                               value: self.formatAllGPURow(gpu),
                               multiline: false)
            self.perGPURows.append((id: gpu.id, label: row.0, value: row.1))
        }
        self.recalculateHeight()
    }

    /// One-line compact representation: "<slot> <util>% <power>W <vram>".
    /// On Apple Silicon (no slot / power / usedVRAM) the row degrades
    /// to "<util>% <temp>°C" — the numbers that actually vary. Missing
    /// values fall back to "—" so an idling GPU still shows up.
    private func formatAllGPURow(_ gpu: GPU_Info) -> String {
        var parts: [String] = []
        let isDiscrete = gpu.type == GPU_types.discrete.rawValue
        if isDiscrete, let slot = gpu.slot {
            parts.append("Slot \(slot)")
        }
        if let u = gpu.utilization {
            parts.append("\(Int(u*100))%")
        }
        if isDiscrete, let p = gpu.powerDraw {
            parts.append(String(format: "%.0fW", p))
        }
        if isDiscrete, let used = gpu.usedVRAM {
            let mib = Double(used) / 1024.0 / 1024.0
            parts.append(String(format: "%.0f MiB", mib))
        }
        if !isDiscrete, let t = gpu.temperature, t > 0 {
            parts.append("\(Int(t))°C")
        }
        if let f = gpu.fanSpeed {
            parts.append("fan \(f)%")
        }
        if let c = gpu.coreClock {
            let mem = gpu.memoryClock.map { " / \($0) MHz" } ?? ""
            parts.append("\(c)\(mem) MHz")
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    // MARK: - Callback

    public func loadCallback(_ value: GPU_Info) {
        self.apply(value, to: self.loadCache, render: self.renderLoad)
        if let utilization = value.utilization {
            self.chart?.addValue(utilization)
        }
    }

    private func renderLoad(_ value: GPU_Info) {
        // Shorten "AMD Radeon PRO W6800X Duo" → "W6800X Duo" so the
        // row fits in a 280pt popup next to the value column.
        // Apple's macOS names are consistent enough that stripping the
        // "AMD Radeon " / "AMD Radeon PRO" prefix is unambiguous.
        let shortModel = value.model
            .replacingOccurrences(of: "AMD Radeon PRO ", with: "")
            .replacingOccurrences(of: "AMD Radeon ", with: "")
        self.modelField?.stringValue = shortModel

        if let cores = value.cores {
            self.coresField?.stringValue = "\(cores)"
        }

        if let utilization = value.utilization {
            self.usageCircle?.toolTip = "\(localizedString("GPU utilization")): \(Int(utilization.rounded(toPlaces: 2) * 100))%"
            self.usageCircle?.setValue(utilization)
            self.usageCircle?.display()
            self.utilizationField?.stringValue = "\(Int(utilization*100))%"
        }
        // The IOAccelerator's PerformanceStatistics dictionary publishes
        // different counters for Apple-Silicon iGPUs and AMD/NVIDIA
        // discrete cards. Hide the rows that don't apply rather than
        // show "—" for every card — a 22pt blank row eats a tenth of
        // the popup height.
        let isIntegrated = value.type == GPU_types.integrated.rawValue
        let isDiscrete   = value.type == GPU_types.discrete.rawValue

        // Discrete-relevant fields. On iGPUs the AMD driver doesn't
        // populate slot / power / usedVRAM, so the rows would be "—"
        // — hide them entirely.
        if isDiscrete {
            self.slotField?.superview?.isHidden = false
            self.powerField?.superview?.isHidden = false
            self.vramField?.superview?.isHidden = false
            self.slotField?.stringValue = value.slot ?? "—"
            self.powerField?.stringValue = value.powerDraw.map { String(format: "%.1f W", $0) } ?? "—"
            if let used = value.usedVRAM {
                // Format as MiB with thousands separator so a 16 GiB
                // card shows "1,614 MiB" and an 8 GiB card shows
                // "8,192 MiB". The total RAM is already shown by the
                // RAM module; this row is just how much the GPU has
                // *committed* right now.
                let mib = Double(used) / 1024.0 / 1024.0
                self.vramField?.stringValue = String(format: "%.0f MiB", mib)
            } else {
                self.vramField?.stringValue = "—"
            }
        } else {
            self.slotField?.superview?.isHidden = true
            self.powerField?.superview?.isHidden = true
            self.vramField?.superview?.isHidden = true
        }

        // Apple-Silicon-only engine counters. The AMD driver does
        // publish Renderer/Tiler/ANE on discrete cards but the
        // numbers are not meaningful (the engine-counting model
        // doesn't apply), so we hide them everywhere except iGPU.
        if isIntegrated {
            self.coresField?.superview?.isHidden = false
            self.renderField?.superview?.isHidden = false
            self.tilerField?.superview?.isHidden = false
            self.aneField?.superview?.isHidden = false
            self.fpsField?.superview?.isHidden = false
            if let utilization = value.renderUtilization {
                self.renderCircle?.toolTip = "\(localizedString("Renderer utilization")): \(Int(utilization.rounded(toPlaces: 2) * 100))%"
                self.renderCircle?.setValue(utilization)
                self.renderCircle?.display()
                self.renderField?.stringValue = "\(Int(utilization*100))%"
            }
            if let utilization = value.tilerUtilization {
                self.tilerCircle?.toolTip = "\(localizedString("Tiler utilization")): \(Int(utilization.rounded(toPlaces: 2) * 100))%"
                self.tilerCircle?.setValue(utilization)
                self.tilerCircle?.display()
                self.tilerField?.stringValue = "\(Int(utilization*100))%"
            }
            if let utilization = value.aneUtilization {
                self.aneField?.stringValue = "\(Int(utilization*100))%"
            }
            if let fps = value.fps {
                self.fpsField?.stringValue = "\(Int(fps.rounded()))"
            }
        } else {
            self.coresField?.superview?.isHidden = true
            self.renderField?.superview?.isHidden = true
            self.tilerField?.superview?.isHidden = true
            self.aneField?.superview?.isHidden = true
            self.fpsField?.superview?.isHidden = true
        }

        // Per-GPU sensors — discrete AMD cards publish every one of these
        // through PerformanceStatistics; Apple Silicon iGPUs leave them nil.
        // Rendering "—" rather than a stale previous value keeps the popup
        // honest when a sensor goes away (e.g. an eGPU is unplugged).
        self.temperatureField?.stringValue = value.temperature.map { "\(Int($0))°C" } ?? "—"
        self.fanSpeedField?.stringValue = value.fanSpeed.map { "\($0)%" } ?? "—"
        if let core = value.coreClock {
            let mem = value.memoryClock.map { " / \($0) MHz" } ?? ""
            self.clockField?.stringValue = "\(core)\(mem) MHz"
        } else {
            self.clockField?.stringValue = "—"
        }

        self.chart?.display()
    }
    
    // MARK: - Settings
    
    public override func settings() -> NSView? {
        let view = SettingsContainerView()
        
        view.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Keyboard shortcut"), component: KeyboardShartcutView(
                callback: self.setKeyboardShortcut,
                value: self.keyboardShortcut
            ))
        ]))
        
        return view
    }
}
