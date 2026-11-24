// CPUPulse — a tiny native macOS menu-bar CPU + memory monitor.
// Draws live CPU-utilization (blue) and memory-used (orange) sparklines in the
// menu bar; left-click opens Activity Monitor; right-click shows a menu.
//
// CPU is normalised 0–100% of total capacity across all cores (100% = every
// core maxed; it cannot exceed 100%). Memory is used / installed RAM.
//
// Idles at a few MB of RAM and negligible CPU — no Electron, no web server.
// Build:  swiftc -O CPUPulse.swift -o CPUPulse   (or ./build.sh for the .app)

import Cocoa

// MARK: - CPU sampling (aggregate across all cores via host_processor_info)

struct CPUSampler {
    private var prevTicks: [UInt32] = []   // flat [user,sys,idle,nice] * ncpu

    /// Total CPU utilization in 0...1 since the previous call.
    mutating func sample() -> Double {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(mach_host_self(),
                                         PROCESSOR_CPU_LOAD_INFO,
                                         &count, &info, &infoCount)
        guard result == KERN_SUCCESS, let info = info else { return 0 }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(bitPattern: info),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }

        let n = Int(count)
        var ticks = [UInt32](repeating: 0, count: n * Int(CPU_STATE_MAX))
        for i in 0 ..< n * Int(CPU_STATE_MAX) {
            ticks[i] = UInt32(bitPattern: info[i])
        }

        defer { prevTicks = ticks }
        guard prevTicks.count == ticks.count else { return 0 }

        var busyDelta: Double = 0
        var totalDelta: Double = 0
        let stride = Int(CPU_STATE_MAX)
        for c in 0 ..< n {
            let base = c * stride
            func d(_ s: Int) -> Double {   // per-core delta, guard counter wrap
                let cur = ticks[base + s], prev = prevTicks[base + s]
                return cur >= prev ? Double(cur - prev) : 0
            }
            let user = d(Int(CPU_STATE_USER))
            let sys  = d(Int(CPU_STATE_SYSTEM))
            let nice = d(Int(CPU_STATE_NICE))
            let idle = d(Int(CPU_STATE_IDLE))
            busyDelta  += user + sys + nice
            totalDelta += user + sys + nice + idle
        }
        guard totalDelta > 0 else { return 0 }
        return min(1.0, max(0.0, busyDelta / totalDelta))
    }
}

// MARK: - Memory sampling (host_statistics64 vs. installed RAM)

struct MemorySampler {
    private let total: Double = {
        var size: UInt64 = 0
        var sz = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &size, &sz, nil, 0)
        return Double(size)
    }()

    /// Memory "used" (active + wired + compressed) / installed RAM, 0...1.
    /// Mirrors roughly what Activity Monitor calls Memory Used.
    func sample() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS, total > 0 else { return 0 }

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let ps = Double(pageSize)

        let used = (Double(stats.active_count)
                    + Double(stats.wire_count)
                    + Double(stats.compressor_page_count)) * ps
        return min(1.0, max(0.0, used / total))
    }

    /// macOS memory-pressure level: 1 = normal, 2 = warning, 4 = critical.
    /// This — not raw used% — is the real risk signal (reflects swapping /
    /// heavy compression), matching Activity Monitor's green/yellow/red.
    func pressureLevel() -> Int {
        var level: Int32 = 1
        var sz = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &sz, nil, 0) == 0 {
            return Int(level)
        }
        return 1
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var cpuSampler = CPUSampler()
    private let memSampler = MemorySampler()
    private var cpuHistory: [Double] = []
    private var memHistory: [Double] = []
    private let maxSamples = 60
    private let interval: TimeInterval = 2.0
    private var timer: Timer?

    // Menu-bar image geometry (points).
    private let graphWidth: CGFloat = 54
    private let graphHeight: CGFloat = 18

    private let cpuColor = NSColor.white      // note: invisible on a light menu bar

    /// Memory line color by pressure level: green = healthy, yellow = tight,
    /// red = critical. Height still shows used%; color shows actual risk.
    private func memColor(forPressure level: Int) -> NSColor {
        switch level {
        case 4...: return .systemRed
        case 2, 3: return .systemYellow
        default:   return .systemGreen
        }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        _ = cpuSampler.sample()   // prime CPU baseline
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        if let timer = timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func tick() {
        let cpu = cpuSampler.sample()
        let mem = memSampler.sample()
        let pressure = memSampler.pressureLevel()
        append(&cpuHistory, cpu)
        append(&memHistory, mem)
        render(cpu: cpu, mem: mem, pressure: pressure)
    }

    private func append(_ arr: inout [Double], _ v: Double) {
        arr.append(v)
        if arr.count > maxSamples { arr.removeFirst(arr.count - maxSamples) }
    }

    // MARK: Drawing

    private func render(cpu: Double, mem: Double, pressure: Int) {
        let size = NSSize(width: graphWidth, height: graphHeight)
        let image = NSImage(size: size)
        image.lockFocus()

        let pad: CGFloat = 1.5
        let w = graphWidth - pad * 2
        let h = graphHeight - pad * 2

        // Gridlines first, so they sit behind the series.
        func hline(_ frac: CGFloat, alpha: CGFloat) {
            let y = pad + frac * h
            let path = NSBezierPath()
            path.lineWidth = 0.5
            path.move(to: NSPoint(x: pad, y: y))
            path.line(to: NSPoint(x: pad + w, y: y))
            NSColor.white.withAlphaComponent(alpha).setStroke()
            path.stroke()
        }
        hline(0.0, alpha: 0.30)   // baseline (0%)
        hline(1.0, alpha: 0.30)   // 100%

        // Memory underneath (color = pressure risk), CPU on top.
        drawSeries(memHistory, color: memColor(forPressure: pressure),
                   pad: pad, w: w, h: h, fill: false, lineWidth: 1.8)
        drawSeries(cpuHistory, color: cpuColor, pad: pad, w: w, h: h, fill: true, lineWidth: 1.2)

        image.unlockFocus()
        image.isTemplate = false   // colored lines — do NOT auto-tint

        if let button = statusItem.button {
            button.image = image
            button.imagePosition = .imageOnly
            let state = pressure >= 4 ? "critical" : (pressure >= 2 ? "warning" : "normal")
            let memDot = pressure >= 4 ? "🔴" : (pressure >= 2 ? "🟡" : "🟢")
            button.toolTip = String(format: "⚪ CPU %.0f%%     %@ Memory %.0f%% (%@)",
                                    cpu * 100, memDot, mem * 100, state)
        }
    }

    private func drawSeries(_ history: [Double], color: NSColor,
                            pad: CGFloat, w: CGFloat, h: CGFloat,
                            fill: Bool, lineWidth: CGFloat) {
        let n = history.count
        guard n >= 2 else { return }
        let step = w / CGFloat(maxSamples - 1)
        func point(_ i: Int) -> NSPoint {
            NSPoint(x: pad + CGFloat(i) * step, y: pad + CGFloat(history[i]) * h)
        }
        if fill {
            let area = NSBezierPath()
            area.move(to: NSPoint(x: point(0).x, y: pad))
            for i in 0 ..< n { area.line(to: point(i)) }
            area.line(to: NSPoint(x: point(n - 1).x, y: pad))
            area.close()
            color.withAlphaComponent(0.18).setFill()
            area.fill()
        }
        let line = NSBezierPath()
        line.lineWidth = lineWidth
        line.lineJoinStyle = .round
        line.move(to: point(0))
        for i in 1 ..< n { line.line(to: point(i)) }
        color.setStroke()
        line.stroke()
    }

    // MARK: Interaction

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        showMenu()
    }

    private func openActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(at: url,
                                           configuration: NSWorkspace.OpenConfiguration(),
                                           completionHandler: nil)
    }

    private func showMenu() {
        let menu = NSMenu()

        // Live values with the same legend dots as the tooltip.
        let cpu = cpuHistory.last ?? 0
        let mem = memHistory.last ?? 0
        let pressure = memSampler.pressureLevel()
        let memDot = pressure >= 4 ? "🔴" : (pressure >= 2 ? "🟡" : "🟢")
        let state = pressure >= 4 ? "critical" : (pressure >= 2 ? "warning" : "normal")
        menu.addItem(withTitle: String(format: "⚪ CPU   %.0f%%", cpu * 100),
                     action: nil, keyEquivalent: "")
        menu.addItem(withTitle: String(format: "%@ Memory   %.0f%%  (%@)", memDot, mem * 100, state),
                     action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        // Peak / average over the retained history.
        func stat(_ label: String, _ hist: [Double]) -> String {
            let peak = (hist.max() ?? 0) * 100
            let avg = hist.isEmpty ? 0 : hist.reduce(0, +) / Double(hist.count) * 100
            return String(format: "%@  peak %.0f%%  avg %.0f%%", label, peak, avg)
        }
        menu.addItem(withTitle: stat("CPU", cpuHistory), action: nil, keyEquivalent: "")
        menu.addItem(withTitle: stat("Mem", memHistory), action: nil, keyEquivalent: "")
        menu.addItem(withTitle: String(format: "last %.0fs", Double(cpuHistory.count) * interval),
                     action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Activity Monitor",
                              action: #selector(menuOpenActivityMonitor), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let quit = NSMenuItem(title: "Quit CPUPulse",
                              action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)   // pops the menu
        statusItem.menu = nil                  // detach so left-click works again
    }

    @objc private func menuOpenActivityMonitor() { openActivityMonitor() }
    @objc private func menuQuit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
