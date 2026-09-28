//
//  portal.swift
//  GPU
//
//  Created by Serhiy Mytrovtsiy on 18/02/2023
//  Using Swift 5.0
//  Running on macOS 13.2
//
//  Copyright © 2023 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit

public class Portal: PortalWrapper {
    private var circle: PieChartView = PieChartView(drawValue: true)

    private var usageField: NSTextField? = nil
    private var aneField: NSTextField? = nil
    private var fpsField: NSTextField? = nil
    private var temperatureField: NSTextField? = nil
    private var clockField: NSTextField? = nil

    private var initialized: Bool = false

    public override func load() {
        let circle = self.circleView()
        let details = self.detailsView()

        self.body.addArrangedSubview(circle)
        self.body.addArrangedSubview(details)
    }

    private func circleView() -> NSView {
        let view: NSStackView = NSStackView()

        view.heightAnchor.constraint(equalToConstant: 70).isActive = true
        view.edgeInsets = NSEdgeInsets(top: 5, left: 5, bottom: 5, right: 5)

        view.addArrangedSubview(self.circle)

        return view
    }

    private func detailsView() -> NSView {
        let view: NSStackView = NSStackView()
        view.orientation = .vertical
        view.distribution = .fillEqually
        view.spacing = Constants.Popup.spacing*2

        self.usageField = portalRow(view, title: "\(localizedString("Usage")):").1
        self.temperatureField = portalRow(view, title: "\(localizedString("Temperature")):").1
        self.clockField = portalRow(view, title: "\(localizedString("Clocks")):").1
        self.aneField = portalRow(view, title: "\("ANE"):").1
        self.fpsField = portalRow(view, title: "\("FPS"):").1

        return view
    }

    internal func callback(_ value: GPU_Info) {
        DispatchQueue.main.async(execute: {
            if (self.window?.isVisible ?? false) || !self.initialized {
                if let value = value.utilization {
                    self.usageField?.stringValue = "\(Int(value*100))%"
                }
                if let ane = value.aneUtilization {
                    self.aneField?.stringValue = "\(Int(ane*100))%"
                }
                if let fps = value.fps {
                    self.fpsField?.stringValue = "\(Int(fps.rounded()))"
                }
                // Discrete AMD cards populate temperature and clocks via the
                // IOAccelerator PerformanceStatistics dictionary; Apple Silicon
                // iGPUs leave these nil and the fields render "—".
                self.temperatureField?.stringValue = value.temperature.map { "\(Int($0))°C" } ?? "—"
                if let core = value.coreClock {
                    let mem = value.memoryClock.map { " / \($0) MHz" } ?? ""
                    self.clockField?.stringValue = "\(core)\(mem) MHz"
                } else {
                    self.clockField?.stringValue = "—"
                }

                self.circle.toolTip = "\(localizedString("GPU utilization")): \(Int(value.utilization!*100))%"
                self.circle.setValue(value.utilization!)

                self.initialized = true
            }
        })
    }
}
