//
//  reader.swift
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

public struct device {
    public let vendor: String?
    public let model: String
    public let pci: String
    public var used: Bool
}

let vendors: [Data: String] = [
    Data.init([0x86, 0x80, 0x00, 0x00]): "Intel",
    Data.init([0x02, 0x10, 0x00, 0x00]): "AMD"
]

private func maxANEPower(for platform: Platform?) -> Double {
    switch platform {
    case .m1, .m1Pro, .m1Max:       return 2.0
    case .m1Ultra:                  return 4.0
    case .m2, .m2Pro, .m2Max:       return 2.5
    case .m2Ultra:                  return 5.0
    case .m3, .m3Pro, .m3Max:       return 3.0
    case .m3Ultra:                  return 6.0
    case .m4, .m4Pro, .m4Max:       return 6.0
    case .m4Ultra:                  return 12.0
    case .m5, .m5Pro, .m5Max:       return 8.0
    case .m5Ultra:                  return 16.0
    default:                        return 8.0
    }
}

internal class InfoReader: Reader<GPUs> {
    private var gpus: GPUs = GPUs()
    private var displays: [gpu_s] = []
    private var devices: [device] = []

    private var aneChannels: CFMutableDictionary? = nil
    private var aneSubscription: IOReportSubscriptionRef? = nil
    private var previousANEEnergy: Double = 0
    private var previousANERead: Date? = nil
    private var aneMaxPower: Double = 8.0

    private var framesChannels: CFMutableDictionary? = nil
    private var framesSubscription: IOReportSubscriptionRef? = nil
    private var previousFramesCount: Int64 = 0
    private var previousFramesTime: CFAbsoluteTime = 0
    
    public override func setup() {
        if let list = SystemKit.shared.device.info.gpu {
            self.displays = list
        }
        
        guard let PCIdevices = fetchIOService("IOPCIDevice") else {
            return
        }
        let devices = PCIdevices.filter{ $0.object(forKey: "IOName") as? String == "display" }
        
        #if arch(arm64)
        self.aneMaxPower = maxANEPower(for: SystemKit.shared.device.platform)
        self.setupANE()
        self.setupFrames()
        #endif
        
        devices.forEach { (dict: NSDictionary) in
            guard let deviceID = dict["device-id"] as? Data, let vendorID = dict["vendor-id"] as? Data else {
                error("device-id or vendor-id not found", log: self.log)
                return
            }
            let pci = "0x" + Data([deviceID[1], deviceID[0], vendorID[1], vendorID[0]]).map { String(format: "%02hhX", $0) }.joined().lowercased()
            
            guard let modelData = dict["model"] as? Data, let modelName = String(data: modelData, encoding: .ascii) else {
                error("GPU model not found", log: self.log)
                return
            }
            let model = modelName.replacingOccurrences(of: "\0", with: "")
            
            var vendor: String? = nil
            if let v = vendors.first(where: { $0.key == vendorID }) {
                vendor = v.value
            }
            
            self.devices.append(device(
                vendor: vendor,
                model: model,
                pci: pci,
                used: false
            ))
        }
    }
    
    public override func read() {
        guard let accelerators = fetchIOService(kIOAcceleratorClassName) else {
            return
        }
        var devices = self.devices
        
        for (index, accelerator) in accelerators.enumerated() {
            guard let IOClass = accelerator.object(forKey: "IOClass") as? String else {
                error("IOClass not found", log: self.log)
                continue
            }
            
            guard let stats = accelerator["PerformanceStatistics"] as? [String: Any] else {
                error("PerformanceStatistics not found", log: self.log)
                continue
            }
            
            var id: String = ""
            var vendor: String? = nil
            var model: String = ""
            var cores: Int? = nil
            let accMatch = (accelerator["IOPCIMatch"] as? String ?? accelerator["IOPCIPrimaryMatch"] as? String ?? "").lowercased()
            
            for (i, device) in devices.enumerated() {
                if accMatch.range(of: device.pci) != nil && !device.used {
                    model = device.model
                    vendor = device.vendor
                    id = "\(model) #\(index)"
                    devices[i].used = true
                    break
                }
            }
            
            let ioClass = IOClass.lowercased()
            var predictModel = ""
            var type: GPU_types = .unknown
            
            let utilization: Int? = stats["Device Utilization %"] as? Int ?? stats["GPU Activity(%)"] as? Int ?? nil
            let renderUtilization: Int? = stats["Renderer Utilization %"] as? Int ?? nil
            let tilerUtilization: Int? = stats["Tiler Utilization %"] as? Int ?? nil
            var temperature: Int? = stats["Temperature(C)"] as? Int ?? nil
            let fanSpeed: Int? = stats["Fan Speed(%)"] as? Int ?? nil
            let coreClock: Int? = stats["Core Clock(MHz)"] as? Int ?? nil
            let memoryClock: Int? = stats["Memory Clock(MHz)"] as? Int ?? nil
            // Discrete-GPU-only fields. Apple Silicon's
            // PerformanceStatistics dictionary doesn't publish these; the
            // macOS AMD driver (AMDRadeonX6000) does.
            let usedVRAM: UInt64? = stats["inUseVidMemoryBytes"] as? UInt64
            let powerDraw: Double? = stats["Total Power(W)"] as? Double

            // Walk up the IORegistry to find the closest
            // IOPCI2PCIBridge with an AAPL,slot-name data property
            // and decode it to UTF-8. This is the same string the
            // About This Mac → PCI Cards tab uses and the Mac Pro
            // service manual labels on the chassis ("Slot-1",
            // "Slot-3", …).
            let slot: String? = Self.appleSlotName(forAccelerator: accelerator)
            
            if ioClass == "nvaccelerator" || ioClass.contains("nvidia") { // nvidia
                predictModel = "Nvidia Graphics"
                type = .discrete
            } else if ioClass.contains("amd") { // amd
                predictModel = "AMD Graphics"
                type = .discrete
                
                if temperature == nil || temperature == 0 {
                    if let tmp = SMC.shared.getValue("TGDD"), tmp != 128 {
                        temperature = Int(tmp)
                    }
                }
            } else if ioClass.contains("intel") { // intel
                predictModel = "Intel Graphics"
                type = .integrated
                
                if temperature == nil || temperature == 0 {
                    if let tmp = SMC.shared.getValue("TCGC"), tmp != 128 {
                        temperature = Int(tmp)
                    }
                }
            } else if ioClass.contains("agx") { // apple
                predictModel = stats["model"] as? String ?? "Apple Graphics"
                if let display = self.displays.first(where: { $0.vendor == "sppci_vendor_Apple" }) {
                    if let name = display.name {
                        predictModel = name
                    }
                    if let num = display.cores {
                        cores = num
                    }
                }
                type = .integrated
            } else {
                predictModel = "Unknown"
                type = .unknown
            }
            
            if model == "" {
                model = predictModel
            }
            if let v = vendor {
                model = model.removedRegexMatches(pattern: v, replaceWith: "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            
            if self.gpus.list.first(where: { $0.id == id }) == nil {
                self.gpus.list.append(GPU_Info(
                    id: id,
                    type: type.rawValue,
                    IOClass: IOClass,
                    vendor: vendor,
                    model: model,
                    cores: cores
                ))
            }
            guard let idx = self.gpus.list.firstIndex(where: { $0.id == id }) else {
                return
            }
            
            if let agcInfo = accelerator["AGCInfo"] as? [String: Int], let state = agcInfo["poweredOffByAGC"] {
                self.gpus.list[idx].state = state == 0
            }
            
            if var value = utilization {
                if value > 100 {
                    value = 100
                }
                self.gpus.list[idx].utilization = Double(value)/100
            }
            if var value = renderUtilization {
                if value > 100 {
                    value = 100
                }
                self.gpus.list[idx].renderUtilization = Double(value)/100
            }
            if var value = tilerUtilization {
                if value > 100 {
                    value = 100
                }
                self.gpus.list[idx].tilerUtilization = Double(value)/100
            }
            if let value = temperature {
                self.gpus.list[idx].temperature = Double(value)
            }
            if let value = fanSpeed {
                self.gpus.list[idx].fanSpeed = value
            }
            if let value = coreClock {
                self.gpus.list[idx].coreClock = value
            }
            if let value = memoryClock {
                self.gpus.list[idx].memoryClock = value
            }
            if let value = usedVRAM {
                self.gpus.list[idx].usedVRAM = value
            }
            if let value = powerDraw {
                self.gpus.list[idx].powerDraw = value
            }
            if let value = slot {
                self.gpus.list[idx].slot = value
            }
        }
        
        #if arch(arm64)
        let anePower = self.readANEPower()
        let aneUtil = anePower.map { min(1.0, max(0.0, $0 / self.aneMaxPower)) }
        let fpsValue = self.readFrames()
        for i in self.gpus.list.indices where self.gpus.list[i].IOClass.lowercased().contains("agx") {
            self.gpus.list[i].aneUtilization = aneUtil ?? 0
            self.gpus.list[i].fps = fpsValue
        }
        #endif
        
        self.gpus.list.sort{ !$0.state && $1.state }
        self.callback(self.gpus)
    }
    
    // MARK: - FPS
    
    private func setupFrames() {
        let groups = ["DCP", "DCP0", "DCPEXT0", "DCPEXT1", "DCPEXT2", "DCPEXT3"]
        var merged: CFMutableDictionary? = nil
        
        for group in groups {
            guard let channel = IOReportCopyChannelsInGroup(group as CFString, "swap" as CFString, 0, 0, 0)?.takeRetainedValue() else { continue }
            if merged == nil {
                merged = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, channel)
            } else {
                IOReportMergeChannels(merged, channel, nil)
            }
        }
        
        guard let merged, let dict = merged as? [String: Any], dict["IOReportChannels"] != nil else { return }
        
        self.framesChannels = merged
        var sub: Unmanaged<CFMutableDictionary>?
        self.framesSubscription = IOReportCreateSubscription(nil, merged, &sub, 0, nil)
        sub?.release()
    }
    
    private func readFrames() -> Double? {
        guard let subscription = self.framesSubscription,
              let channels = self.framesChannels,
              let sample = IOReportCreateSamples(subscription, channels, nil)?.takeRetainedValue(),
              let dict = sample as? [String: Any],
              let channelsList = dict["IOReportChannels"] as? NSArray else {
            return nil
        }
        let items = channelsList as CFArray
        
        var total: Int64 = 0
        for i in 0..<CFArrayGetCount(items) {
            let item = unsafeBitCast(CFArrayGetValueAtIndex(items, i), to: CFDictionary.self)
            guard let group = IOReportChannelGetGroup(item)?.takeUnretainedValue() as? String,
                  group.hasPrefix("DCP"),
                  let sub = IOReportChannelGetSubGroup(item)?.takeUnretainedValue() as? String,
                  sub == "swap" else { continue }
            total += IOReportSimpleGetIntegerValue(item, 0)
        }
        
        let now = CFAbsoluteTimeGetCurrent()
        defer {
            self.previousFramesCount = total
            self.previousFramesTime = now
        }
        
        guard self.previousFramesTime != 0 else { return nil }
        let elapsed = now - self.previousFramesTime
        guard elapsed > 0 else { return nil }
        let delta = total - self.previousFramesCount
        guard delta >= 0 else { return nil }
        return Double(delta) / elapsed
    }
    
    // MARK: - ANE power
    
    private func setupANE() {
        guard let channel = IOReportCopyChannelsInGroup("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue() else { return }
        
        let size = CFDictionaryGetCount(channel)
        guard let mutable = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, size, channel),
              let dict = mutable as? [String: Any], dict["IOReportChannels"] != nil else { return }
        
        self.aneChannels = mutable
        var sub: Unmanaged<CFMutableDictionary>?
        self.aneSubscription = IOReportCreateSubscription(nil, mutable, &sub, 0, nil)
        sub?.release()
    }
    
    private func readANEPower() -> Double? {
        guard let subscription = self.aneSubscription,
              let channels = self.aneChannels,
              let reportSample = IOReportCreateSamples(subscription, channels, nil)?.takeRetainedValue(),
              let dict = reportSample as? [String: Any],
              let channelsList = dict["IOReportChannels"] as? NSArray else {
            return nil
        }
        let items = channelsList as CFArray
        
        var currentEnergy: Double = 0
        var found = false
        
        for i in 0..<CFArrayGetCount(items) {
            let item = unsafeBitCast(CFArrayGetValueAtIndex(items, i), to: CFDictionary.self)
            
            guard let group = IOReportChannelGetGroup(item)?.takeUnretainedValue() as? String,
                  group == "Energy Model",
                  let channel = IOReportChannelGetChannelName(item)?.takeUnretainedValue() as? String,
                  channel.starts(with: "ANE") else { continue }
            
            let raw = Double(IOReportSimpleGetIntegerValue(item, 0))
            let unit = (IOReportChannelGetUnitLabel(item)?.takeUnretainedValue() as? String)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            
            let joules: Double
            switch unit.lowercased() {
            case "mj":       joules = raw / 1e3
            case "uj", "µj": joules = raw / 1e6
            case "nj":       joules = raw / 1e9
            case "pj":       joules = raw / 1e12
            default:         joules = raw / 1e9
            }
            
            currentEnergy += joules
            found = true
        }
        
        guard found else { return nil }
        
        let now = Date()
        defer {
            self.previousANEEnergy = currentEnergy
            self.previousANERead = now
        }
        
        guard let previousRead = self.previousANERead else { return 0 }
        let elapsed = now.timeIntervalSince(previousRead)
        guard elapsed > 0 else { return 0 }
        return (currentEnergy - self.previousANEEnergy) / elapsed
    }

    /// Walk up the IORegistry from an IOAccelerator (the GPU's userland
    /// object) to the closest ancestor carrying an AAPL,slot-name
    /// data property and decode it to UTF-8. Apple's IORegistry exposes
    /// this on every IOPCI2PCIBridge in the Mac Pro chassis; the value
    /// is the same string About This Mac → PCI Cards and the Mac Pro
    /// service manual use ("Slot-1", "Slot-3", "Slot-8" on a 7,1).
    /// Returns nil on Apple Silicon (no PCI), on Intel iGPUs (no
    /// bridge), or when the data property is missing.
    private static func appleSlotName(forAccelerator accelerator: NSDictionary) -> String? {
        // Get the IOAccelerator's IORegistry entry from its IOClass key.
        // We don't have a direct reference; instead we walk from the
        // global IOPCIDevice table matching by IOPCIMatch against
        // the accelerator's bus/device-id. Then walk up the parent
        // chain to find AAPL,slot-name.
        guard let accClass = accelerator["IOClass"] as? String else { return nil }
        let accMatch = (accelerator["IOPCIMatch"] as? String ?? accelerator["IOPCIPrimaryMatch"] as? String ?? "").lowercased()
        guard !accMatch.isEmpty,
              let allPCI = fetchIOService("IOPCIDevice") else { return nil }
        var target: NSDictionary? = nil
        for dict in allPCI where (dict["IOClass"] as? String) == accClass {
            if let m = (dict["IOPCIMatch"] as? String ?? dict["IOPCIPrimaryMatch"] as? String ?? "").lowercased() as String?,
               m.contains(accMatch) || accMatch.contains(m) {
                target = dict
                break
            }
        }
        guard let device = target else { return nil }

        // The IOPCIDevice for a discrete AMD card is reached by walking
        // up from the IOAccelerator's grandparent (the IOGraphicsAccelerator2
        // sits between the accelerator and the PCI device). Use the
        // entry's "parent" path via the IORegistry path.
        guard let path = (device["acpi-path"] as? String) ?? (device["IOPCIPath"] as? String) else {
            return nil
        }
        // Apple publishes the slot name as a sibling of the device
        // on the same bridge. Walk all IOPCIBridge entries and find
        // the one whose path is a prefix of ours.
        guard let bridges = fetchIOService("IOPCI2PCIBridge") else { return nil }
        for bridge in bridges {
            guard let bridgePath = (bridge["acpi-path"] as? String) ?? (bridge["IOPCIPath"] as? String) else { continue }
            if path.hasPrefix(bridgePath) || bridgePath.hasPrefix(path) {
                if let slot = decodeSlotName(from: bridge) { return slot }
            }
        }
        return nil
    }

    /// Decode the AAPL,slot-name data property (a CFData wrapping
    /// UTF-8 padded to a 4-byte boundary) to a Swift String.
    private static func decodeSlotName(from bridge: NSDictionary) -> String? {
        guard let raw = bridge["AAPL,slot-name"] as? Data else { return nil }
        // Strip trailing 0x00 and any high-bit padding bytes that
        // Apple uses to round the UTF-8 string up to a 4-byte
        // boundary.
        var end = raw.count
        while end > 0 {
            let b = raw[end - 1]
            if b == 0 || b > 0x7E { end -= 1 } else { break }
        }
        guard end > 0 else { return nil }
        return String(data: raw.prefix(end), encoding: .utf8)
    }
}
