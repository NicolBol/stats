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
    // 8 rows for the selected GPU (added temperature/fan/clock), plus a separator
    // and one "per-GPU" row per active GPU so a multi-GPU Mac Pro lists every
    // GPU instead of collapsing to the active one.
    private let detailsHeight: CGFloat = (22*8) + Constants.Popup.separatorHeight

    private let loadCache = PopupCache<GPU_Info>()

    private var usageCircle: PieChartView? = nil
    private var renderCircle: PieChartView? = nil
    private var tilerCircle: PieChartView? = nil

    private var chart: LineChartView? = nil
    private var lineChartHistory: Int = 180
    private var lineChartScale: Scale = .none
    private var lineChartFixedScale: Double = 1

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

        self.modelField = popupRow(container, title: "\(localizedString("Model")):", value: "").1
        self.coresField = popupRow(container, title: "\(localizedString("Cores")):", value: localizedString("Unknown")).1
        self.utilizationField = popupRow(container, title: "\(localizedString("Utilization")):", value: "").1
        self.renderField = popupRow(container, title: "\(localizedString("Renderer utilization")):", value: "").1
        self.tilerField = popupRow(container, title: "\(localizedString("Tiler utilization")):", value: "").1
        self.aneField = popupRow(container, title: "\(localizedString("ANE utilization")):", value: "").1
        self.temperatureField = popupRow(container, title: "\(localizedString("Temperature")):", value: "").1
        self.fanSpeedField = popupRow(container, title: "\(localizedString("Fan speed")):", value: "").1
        self.clockField = popupRow(container, title: "\(localizedString("Clocks")):", value: "").1
        self.fpsField = popupRow(container, title: "\("FPS"):", value: "").1

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

    /// One-line compact representation: "<util>% <temp>°C <fan>%".
    /// Missing values fall back to "—" so an idling GPU still shows up.
    private func formatAllGPURow(_ gpu: GPU_Info) -> String {
        var parts: [String] = []
        if let u = gpu.utilization {
            parts.append("\(Int(u*100))%")
        }
        if let t = gpu.temperature, t > 0 {
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
        self.modelField?.stringValue = value.model

        if let cores = value.cores {
            self.coresField?.stringValue = "\(cores)"
        }

        if let utilization = value.utilization {
            self.usageCircle?.toolTip = "\(localizedString("GPU utilization")): \(Int(utilization.rounded(toPlaces: 2) * 100))%"
            self.usageCircle?.setValue(utilization)
            self.usageCircle?.display()
            self.utilizationField?.stringValue = "\(Int(utilization*100))%"
        }
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
