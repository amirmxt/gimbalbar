import SwiftUI
import AVFoundation
import Carbon.HIToolbox

// MARK: - Live preview

final class Preview: ObservableObject {
    let session = AVCaptureSession()
    @Published var status = "Starting camera…"
    private let queue = DispatchQueue(label: "gimbal.preview")
    private var configured = false

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else {
                DispatchQueue.main.async { self.status = "Camera access denied in System Settings" }
                return
            }
            self.queue.async {
                if !self.configured { self.configure() }
                if self.configured, !self.session.isRunning { self.session.startRunning() }
            }
        }
    }

    func stop() {
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    private func configure() {
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)
            .devices.first { $0.localizedName.localizedCaseInsensitiveContains("pocket") || $0.modelID.contains("VendorID_11427") }
        guard let device = found, let input = try? AVCaptureDeviceInput(device: device) else {
            DispatchQueue.main.async { self.status = "Pocket 3 not found" }
            return
        }
        session.beginConfiguration()
        session.sessionPreset = .medium
        if session.canAddInput(input) { session.addInput(input) }
        session.commitConfiguration()
        configured = true
        DispatchQueue.main.async { self.status = "" }
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
    private var timer: Timer?

    init() {
        refresh()
        usb.async {
            var r = ptz_range_t()
            if ptz_range(&r) == 0 { Task { @MainActor in self.range = r } }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            Task { @MainActor in self.refresh() }
        }
    }

    func refresh() {
        guard !sending else { return }
        usb.async {
            var p = 0.0, t = 0.0
            let ok = ptz_get(&p, &t) == 0
            Task { @MainActor in
                self.connected = ok
                if ok, !self.sending { self.pan = p; self.tilt = t }
            }
        }
    }

    // Latest target wins; USB writes never queue up behind a drag.
    func go(pan: Double, tilt: Double) {
        let p = min(max(pan, range.panMin), range.panMax)
        let t = min(max(tilt, range.tiltMin), range.tiltMax)
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
    @State private var dragging = false

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
