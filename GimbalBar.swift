import SwiftUI
import AVFoundation
import Carbon.HIToolbox

// Avoid Swift 6.4 @State macro expansion: Command Line Tools may lack SwiftUIMacros.
// This alias retains Apple's SwiftUI.State property-wrapper behavior.
private typealias StoredState<Value> = SwiftUI.State<Value>

// MARK: - Live preview

final class Preview: ObservableObject {
    let session = AVCaptureSession()
    @Published var status = "Starting camera…"
    private let queue = DispatchQueue(label: "gimbal.preview")
    private var active = false
    private var authorized = false
    private var observers: [NSObjectProtocol] = []

    init() {
        // Camera sessions can retain stale inputs after unplug/replug.
        let notifications = [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification]
        observers = notifications.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.refreshDevice() }
            }
        }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func start() {
        queue.async { self.active = true }
        AVCaptureDevice.requestAccess(for: .video) { granted in
            self.queue.async {
                guard self.active else { return }
                self.authorized = granted
                guard granted else {
                    DispatchQueue.main.async { self.status = "Camera access denied in System Settings" }
                    return
                }
                self.refreshDevice()
            }
        }
    }

    func stop() {
        queue.async {
            self.active = false
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    // All session configuration and start/stop operations run on one serial queue.
    private func refreshDevice() {
        guard active && authorized else { return }
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)
            .devices.first { $0.localizedName.localizedCaseInsensitiveContains("pocket") || $0.modelID.contains("VendorID_11427") }
        let current = session.inputs.compactMap { $0 as? AVCaptureDeviceInput }.first

        if let found, current?.device.uniqueID == found.uniqueID {
            if !session.isRunning { session.startRunning() }
            DispatchQueue.main.async { self.status = "" }
            return
        }

        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        var ready = false
        if let found, let input = try? AVCaptureDeviceInput(device: found), session.canAddInput(input) {
            session.addInput(input)
            ready = true
        }
        session.commitConfiguration()

        if ready { session.startRunning() }
        DispatchQueue.main.async {
            self.status = ready ? "" : (found == nil ? "Pocket 3 not found" : "Unable to open Pocket 3 camera")
        }
    }
}

struct PreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    final class LayerView: NSView {
        let previewLayer: AVCaptureVideoPreviewLayer

        init(session: AVCaptureSession) {
            previewLayer = AVCaptureVideoPreviewLayer(session: session)
            previewLayer.videoGravity = .resizeAspectFill
            super.init(frame: .zero)
            wantsLayer = true
            layer?.addSublayer(previewLayer)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            previewLayer.frame = bounds
        }
    }

    func makeNSView(context: Context) -> LayerView { LayerView(session: session) }

    func updateNSView(_ nsView: LayerView, context: Context) {}
}

// MARK: - Gimbal controller

@MainActor
final class Gimbal: ObservableObject {
    static let shared = Gimbal()

    @Published var pan = 0.0
    @Published var tilt = 0.0
    @Published var connected = false
    @Published var range = ptz_range_t(panMin: -35, panMax: 215, tiltMin: -90, tiltMax: 90)

    @AppStorage("step") var step = 15.0
    @AppStorage("invertPan") var invertPan = false
    @AppStorage("homePan") var homePan = 180.0
    @AppStorage("homeTilt") var homeTilt = 0.0

    private let usb = DispatchQueue(label: "gimbal.usb")
    private var pending: (Double, Double)?
    private var sending = false
    private var reading = false
    private var moveRevision: UInt64 = 0
    private var rangeAttempted = false
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            Task { @MainActor in self.refresh() }
        }
    }

    func refresh() {
        // Never accumulate USB reads if the device is slow or disconnected.
        guard !sending && !reading else { return }
        reading = true
        let revision = moveRevision
        let probeRange = !rangeAttempted
        usb.async {
            var p = 0.0, t = 0.0
            let ok = ptz_get(&p, &t) == 0
            var discoveredRange = ptz_range_t()
            let gotRange = ok && probeRange && ptz_range(&discoveredRange) == 0
            Task { @MainActor in
                self.reading = false
                self.connected = ok
                if ok {
                    if probeRange { self.rangeAttempted = true }
                    if gotRange { self.range = discoveredRange }
                    // Ignore a stale read that began before a user movement.
                    if !self.sending && self.moveRevision == revision {
                        self.pan = p
                        self.tilt = t
                    }
                } else {
                    // Re-read device limits the next time the camera comes back.
                    self.rangeAttempted = false
                }
            }
        }
    }

    // Latest target wins; USB writes never queue up behind a drag.
    func go(pan: Double, tilt: Double) {
        guard connected else { return }
        let p = min(max(pan, range.panMin), range.panMax)
        let t = min(max(tilt, range.tiltMin), range.tiltMax)
        moveRevision &+= 1
        self.pan = p
        self.tilt = t
        pending = (p, t)
        guard !sending else { return }
        sending = true
        flush()
    }

    private func flush() {
        guard let (p, t) = pending else { sending = false; return }
        pending = nil
        usb.async {
            let ok = ptz_set(p, t) == 0
            Task { @MainActor in
                self.connected = ok
                if !ok {
                    // Stop issuing queued moves after a USB error.
                    self.pending = nil
                    self.sending = false
                    self.rangeAttempted = false
                    return
                }
                self.flush()
            }
        }
    }

    func nudge(dx: Double, dy: Double) {
        let sign = invertPan ? -1.0 : 1.0
        go(pan: pan + dx * step * sign, tilt: tilt + dy * step)
    }

    func recenter() { go(pan: homePan, tilt: homeTilt) }

    func setHome() {
        homePan = pan
        homeTilt = tilt
    }
}

// MARK: - Global hotkeys (⌃⌥ + arrows, ⌃⌥C)

enum HotKeys {
    private static var refs: [EventHotKeyRef?] = []

    static func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            Task { @MainActor in
                let g = Gimbal.shared
                switch id.id {
                case 1: g.nudge(dx: -1, dy: 0)
                case 2: g.nudge(dx: 1, dy: 0)
                case 3: g.nudge(dx: 0, dy: 1)
                case 4: g.nudge(dx: 0, dy: -1)
                case 5: g.recenter()
                default: break
                }
            }
            return noErr
        }, 1, &spec, nil, nil)

        let mods = UInt32(controlKey | optionKey)
        let keys = [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_ANSI_C]
        for (i, key) in keys.enumerated() {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(key), mods, EventHotKeyID(signature: OSType(0x47424152), id: UInt32(i + 1)),
                                GetApplicationEventTarget(), 0, &ref)
            refs.append(ref)
        }
    }
}

// MARK: - Views

struct Pad: View {
    @ObservedObject var g: Gimbal
    @StoredState private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let r = g.range
            let sign = g.invertPan ? -1.0 : 1.0
            let fx = (g.pan - r.panMin) / (r.panMax - r.panMin)
            let x = (sign > 0 ? fx : 1 - fx) * w
            let y = (1 - (g.tilt - r.tiltMin) / (r.tiltMax - r.tiltMin)) * h

            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.quaternary.opacity(0.6))
                Path { p in
                    p.move(to: CGPoint(x: w / 2, y: 0)); p.addLine(to: CGPoint(x: w / 2, y: h))
                    p.move(to: CGPoint(x: 0, y: h / 2)); p.addLine(to: CGPoint(x: w, y: h / 2))
                }
                .stroke(.tertiary, style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))

                Circle()
                    .fill(.tint)
                    .frame(width: dragging ? 22 : 16, height: dragging ? 22 : 16)
                    .shadow(color: .accentColor.opacity(0.5), radius: dragging ? 8 : 4)
                    .position(x: x, y: y)
                    .animation(.spring(response: 0.25, dampingFraction: 0.8), value: dragging)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    dragging = true
                    var fx = min(max(v.location.x / w, 0), 1)
                    if sign < 0 { fx = 1 - fx }
                    let fy = 1 - min(max(v.location.y / h, 0), 1)
                    g.go(pan: r.panMin + fx * (r.panMax - r.panMin),
                         tilt: r.tiltMin + fy * (r.tiltMax - r.tiltMin))
                }
                .onEnded { _ in dragging = false })
        }
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct ArrowButton: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 34, height: 34)
                .background(.quaternary.opacity(0.7), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

struct Panel: View {
    @ObservedObject var g = Gimbal.shared
    @StateObject private var preview = Preview()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Osmo Pocket 3").font(.headline)
                    HStack(spacing: 5) {
                        Circle().fill(g.connected ? .green : .secondary).frame(width: 6, height: 6)
                        Text(g.connected ? "Connected" : "Not connected")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Pan \(Int(g.pan.rounded()))°")
                    Text("Tilt \(Int(g.tilt.rounded()))°")
                }
                .font(.system(.caption, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
            }

            ZStack {
                Rectangle().fill(.black)
                PreviewView(session: preview.session)
                if !preview.status.isEmpty {
                    Text(preview.status).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 288, height: 162) // 16:9 at the panel's content width; video views have no intrinsic size
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))

            Pad(g: g)

            HStack(spacing: 16) {
                Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                    GridRow {
                        Color.clear.frame(width: 34, height: 34)
                        ArrowButton(symbol: "chevron.up") { g.nudge(dx: 0, dy: 1) }
                        Color.clear.frame(width: 34, height: 34)
                    }
                    GridRow {
                        ArrowButton(symbol: "chevron.left") { g.nudge(dx: -1, dy: 0) }
                        ArrowButton(symbol: "scope") { g.recenter() }
                        ArrowButton(symbol: "chevron.right") { g.nudge(dx: 1, dy: 0) }
                    }
                    GridRow {
                        Color.clear.frame(width: 34, height: 34)
                        ArrowButton(symbol: "chevron.down") { g.nudge(dx: 0, dy: -1) }
                        Color.clear.frame(width: 34, height: 34)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Step").font(.caption).foregroundStyle(.secondary)
                    Picker("Step", selection: $g.step) {
                        Text("5°").tag(5.0)
                        Text("15°").tag(15.0)
                        Text("30°").tag(30.0)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    Button("Set as Center") { g.setHome() }
                        .controlSize(.small)
                    Toggle("Invert Pan", isOn: $g.invertPan)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                }
            }

            Divider()

            HStack {
                Text("⌃⌥ ←↑↓→ move   ⌃⌥C center")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 320)
        .onAppear { preview.start() }
        .onDisappear { preview.stop() }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { g.nudge(dx: -1, dy: 0); return .handled }
        .onKeyPress(.rightArrow) { g.nudge(dx: 1, dy: 0); return .handled }
        .onKeyPress(.upArrow) { g.nudge(dx: 0, dy: 1); return .handled }
        .onKeyPress(.downArrow) { g.nudge(dx: 0, dy: -1); return .handled }
    }
}

@main
struct GimbalBarApp: App {
    init() { HotKeys.register() }

    var body: some Scene {
        MenuBarExtra("Gimbal", systemImage: "camera.viewfinder") {
            Panel()
        }
        .menuBarExtraStyle(.window)
    }
}
