import SwiftUI
import AVFoundation
import Carbon.HIToolbox

// Avoid Swift 6.4 @State macro expansion: Command Line Tools may lack SwiftUIMacros.
// This alias retains Apple's SwiftUI.State property-wrapper behavior.
private typealias StoredState<Value> = SwiftUI.State<Value>

// MARK: - Live preview

final class Preview: ObservableObject {
    let session = AVCaptureSession()
    @Published var status = "Iniciando câmera…"
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
                    DispatchQueue.main.async { self.status = "Acesso à câmera negado. Verifique os Ajustes do Sistema." }
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
            self.status = ready ? "" : (found == nil ? "Pocket 3 não encontrada" : "Não foi possível abrir a câmera Pocket 3")
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

// MARK: - Saved camera positions

struct SavedPosition: Codable {
    let slot: Int
    let pan: Double
    let tilt: Double
}

// MARK: - Gimbal controller

@MainActor
final class Gimbal: ObservableObject {
    static let shared = Gimbal()

    @Published var pan = 0.0
    @Published var tilt = 0.0
    @Published var connected = false
    @Published var range = ptz_range_t(panMin: -35, panMax: 215, tiltMin: -90, tiltMax: 90)
    @Published private(set) var savedPositions: [SavedPosition] = []
    @Published private(set) var isTransitioning = false
    // zoom é o alvo selecionado no controle; zoomActual é o último valor lido da câmera.
    @Published var zoom = 1.0
    @Published private(set) var zoomActual = 1.0
    @Published private(set) var zoomMin = 1.0
    @Published private(set) var zoomMax = 4.0
    @Published private(set) var zoomAvailable = false
    @Published private(set) var zoomStatus = "Conecte a Pocket 3"

    @AppStorage("step") var step = 15.0
    @AppStorage("invertPan") var invertPan = false
    @AppStorage("homePan") var homePan = 180.0
    @AppStorage("homeTilt") var homeTilt = 0.0
    // Degrees per 200 ms software step. This is not a hardware motor-speed setting.
    @AppStorage("presetMotionStep") var presetMotionStep = 6.0
    @AppStorage("hotkeysEnabled") var hotkeysEnabled = true
    @AppStorage("hotkeyModifiers") var hotkeyModifiers = 0
    @Published var hotkeyStatus = ""

    var shortcutPrefix: String {
        switch hotkeyModifiers {
        case 1: return "⌘⌥"
        case 2: return "⌃⇧"
        default: return "⌃⌥"
        }
    }

    private let usb = DispatchQueue(label: "gimbal.usb")
    private var pending: (Double, Double)?
    private var sending = false
    private var reading = false
    private var moveRevision: UInt64 = 0
    private var rangeAttempted = false
    private var zoomRangeAttempted = false
    private var zoomPollingTicks = 0
    private var zoomEditing = false
    private var zoomSending = false
    private var zoomPending: Int32?
    private var zoomCommitTimer: Timer?
    private var zoomRevision: UInt64 = 0
    private var zoomSettlingUntil = Date.distantPast
    private var timer: Timer?
    private var transitionTimer: Timer?
    private var transitionDestination: (pan: Double, tilt: Double)?
    private let positionsKey = "ov.gimbalbar.savedPositions.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: positionsKey),
           let positions = try? JSONDecoder().decode([SavedPosition].self, from: data) {
            savedPositions = positions.filter { (1...3).contains($0.slot) }
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            Task { @MainActor in self.refresh() }
        }
    }

    func refresh() {
        // PTZ and zoom share a single serial IOKit USB queue.
        guard !sending && !reading && !zoomSending else { return }
        reading = true
        let revision = moveRevision
        let probeRange = !rangeAttempted
        let probeZoom = !zoomRangeAttempted
        zoomPollingTicks += 1
        let readZoom = probeZoom || zoomPollingTicks >= 2
        if readZoom { zoomPollingTicks = 0 }
        let zoomReadRevision = zoomRevision
        usb.async {
            var p = 0.0, t = 0.0
            let ok = ptz_get(&p, &t) == 0
            var discoveredRange = ptz_range_t()
            let gotRange = ok && probeRange && ptz_range(&discoveredRange) == 0

            var zMin: Int32 = 0, zMax: Int32 = 0, zCurrent: Int32 = 0
            let gotZoomRange = ok && probeZoom && ptz_zoom_range(&zMin, &zMax) == 0
            let gotZoomCurrent = ok && readZoom && ptz_zoom_get(&zCurrent) == 0

            Task { @MainActor in
                self.reading = false
                self.connected = ok
                if ok {
                    if probeRange { self.rangeAttempted = true }
                    if gotRange { self.range = discoveredRange }
                    if probeZoom {
                        self.zoomRangeAttempted = true
                        // Limit the experimental UI to the camera's verified 1×–4× range.
                        self.zoomAvailable = gotZoomRange && zMin >= 100
                            && zMax <= 400 && zMax > zMin
                        if self.zoomAvailable {
                            self.zoomMin = Double(zMin) / 100.0
                            self.zoomMax = Double(zMax) / 100.0
                            self.zoomStatus = ""
                        } else {
                            self.zoomStatus = "Zoom nativo indisponível via USB"
                        }
                    }
                    // Exibir a leitura real separadamente. Leituras iniciadas antes de
                    // um novo comando nunca devem empurrar a posição do controle.
                    if gotZoomCurrent && self.zoomAvailable &&
                        self.zoomRevision == zoomReadRevision && !self.zoomSending {
                        let measured = min(max(Double(zCurrent) / 100.0,
                                               self.zoomMin), self.zoomMax)
                        self.zoomActual = measured
                        if !self.zoomEditing && self.zoomPending == nil &&
                           Date() >= self.zoomSettlingUntil {
                            // Somente um valor lido depois da estabilização move
                            // o slider; assim ele espelha a posição real informada.
                            self.zoom = measured
                            self.zoomStatus = ""
                        }
                    }
                    // Ignore stale PTZ reads invalidated by a user movement.
                    if !self.sending && !self.isTransitioning &&
                        self.moveRevision == revision {
                        self.pan = p
                        self.tilt = t
                    }
                } else {
                    // Re-probe on the next USB reconnect.
                    self.rangeAttempted = false
                    self.zoomRangeAttempted = false
                    self.zoomAvailable = false
                    self.zoomEditing = false
                    self.zoomPending = nil
                    self.zoomCommitTimer?.invalidate()
                    self.zoomCommitTimer = nil
                    self.zoomRevision &+= 1
                    self.zoomStatus = "Conecte a Pocket 3"
                    self.cancelTransition()
                }
            }
        }
    }

    // Os comandos são agrupados: no máximo uma escrita por janela de 160 ms.
    // A seleção continua responsiva durante escritas USB; o último alvo vence.
    func selectZoom(_ requested: Double) {
        guard connected && zoomAvailable else { return }
        let clamped = min(max(requested, zoomMin), zoomMax)
        let target = (clamped * 10.0).rounded() / 10.0
        zoom = target
        zoomPending = Int32((target * 100.0).rounded())
        zoomRevision &+= 1
        zoomStatus = "Ajustando zoom…"
        scheduleZoomCommit()
    }

    func zoomEditingChanged(_ editing: Bool) {
        zoomEditing = editing
        if !editing {
            // Enviar a última posição assim que o usuário soltar.
            zoomCommitTimer?.invalidate()
            zoomCommitTimer = nil
            sendPendingZoom()
        }
    }

    func setZoom(_ requested: Double) {
        // Mesmo caminho do slider: botão 1× pode interromper uma escrita lenta
        // e enfileira somente o novo alvo, sem bloquear a interface.
        selectZoom(requested)
        zoomCommitTimer?.invalidate()
        zoomCommitTimer = nil
        sendPendingZoom()
    }

    private func scheduleZoomCommit() {
        guard zoomCommitTimer == nil && !zoomSending else { return }
        zoomCommitTimer = Timer.scheduledTimer(withTimeInterval: 0.16,
                                               repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.zoomCommitTimer = nil
                self?.sendPendingZoom()
            }
        }
    }

    private func sendPendingZoom() {
        guard connected && zoomAvailable && !zoomSending,
              let target = zoomPending else { return }
        zoomPending = nil
        zoomSending = true
        let verifiedMin = Int32((zoomMin * 100.0).rounded())
        let verifiedMax = Int32((zoomMax * 100.0).rounded())

        usb.async {
            // Limites verificados na conexão e novamente validados no driver C.
            // Evita dois GETs extras a cada pequena alteração.
            let ok = ptz_zoom_set_checked(target, verifiedMin, verifiedMax) == 0
            Task { @MainActor in
                self.zoomSending = false
                if !ok {
                    self.zoomPending = nil
                    self.zoomCommitTimer?.invalidate()
                    self.zoomCommitTimer = nil
                    self.zoomStatus = "Falha ao enviar zoom; reconecte a câmera"
                    self.zoomAvailable = false
                    self.zoomRangeAttempted = false
                    return
                }
                self.zoomSettlingUntil = Date().addingTimeInterval(1.2)
                self.zoomStatus = "Aguardando confirmação da câmera…"
                if self.zoomPending != nil {
                    self.scheduleZoomCommit()
                }
            }
        }
    }

    // Any manual move cancels the remaining preset trajectory.
    func go(pan: Double, tilt: Double) {
        cancelTransition()
        sendTarget(pan: pan, tilt: tilt)
    }

    // Latest target wins; never build a backlog of USB move commands.
    private func sendTarget(pan: Double, tilt: Double) {
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

    func savedPosition(slot: Int) -> SavedPosition? {
        savedPositions.first { $0.slot == slot }
    }

    func savePosition(slot: Int) {
        guard connected, !sending, !isTransitioning, (1...3).contains(slot) else { return }
        let position = SavedPosition(slot: slot, pan: pan, tilt: tilt)
        savedPositions.removeAll { $0.slot == slot }
        savedPositions.append(position)
        savedPositions.sort { $0.slot < $1.slot }
        if let data = try? JSONEncoder().encode(savedPositions) {
            UserDefaults.standard.set(data, forKey: positionsKey)
        }
    }

    func recallPosition(slot: Int) {
        guard let saved = savedPosition(slot: slot) else { return }
        moveSmoothly(pan: saved.pan, tilt: saved.tilt)
    }

    // UVC exposes absolute positions, not a reliable motor-speed interface.
    // Interpolate conservative 200 ms position steps, clamped to device limits.
    func moveSmoothly(pan: Double, tilt: Double) {
        guard connected else { return }
        cancelTransition()
        transitionDestination = (
            pan: min(max(pan, range.panMin), range.panMax),
            tilt: min(max(tilt, range.tiltMin), range.tiltMax)
        )
        isTransitioning = true
        advanceTransition()
        if isTransitioning {
            transitionTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.advanceTransition() }
            }
        }
    }

    private func advanceTransition() {
        guard connected, let target = transitionDestination else {
            cancelTransition()
            return
        }
        // Wait for the prior USB write to finish before issuing the next motor target.
        guard !sending else { return }
        let dx = target.pan - pan
        let dy = target.tilt - tilt
        let remaining = hypot(dx, dy)
        if remaining < 0.01 {
            cancelTransition()
            return
        }
        let step = min(max(presetMotionStep, 1.0), 9.0)
        let fraction = min(1.0, step / remaining)
        sendTarget(pan: pan + dx * fraction, tilt: tilt + dy * fraction)
        if fraction >= 1.0 { cancelTransition() }
    }

    private func cancelTransition() {
        transitionTimer?.invalidate()
        transitionTimer = nil
        transitionDestination = nil
        isTransitioning = false
    }

    func stopTransition() {
        cancelTransition()
        // The in-flight USB request cannot be retracted; no further steps are queued.
        pending = nil
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
                    self.cancelTransition()
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

    func recenter() { moveSmoothly(pan: homePan, tilt: homeTilt) }

    func setHome() {
        homePan = pan
        homeTilt = tilt
    }
}

// MARK: - Global shortcuts

enum HotKeys {
    private static var refs: [EventHotKeyRef?] = []
    private static var handlerInstalled = false
    private(set) static var status = "Não configurados"

    static func register() {
        if !handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var id = EventHotKeyID()
                let result = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id
                )
                guard result == noErr else { return noErr }
                Task { @MainActor in
                    let g = Gimbal.shared
                    switch id.id {
                    case 1: g.nudge(dx: -1, dy: 0)
                    case 2: g.nudge(dx: 1, dy: 0)
                    case 3: g.nudge(dx: 0, dy: 1)
                    case 4: g.nudge(dx: 0, dy: -1)
                    case 5: g.recenter()
                    case 6: g.recallPosition(slot: 1)
                    case 7: g.recallPosition(slot: 2)
                    case 8: g.recallPosition(slot: 3)
                    default: break
                    }
                }
                return noErr
            }, 1, &spec, nil, nil)
            guard result == noErr else {
                status = "Não foi possível registrar os atalhos globais"
                return
            }
            handlerInstalled = true
        }
        _ = configure()
    }

    @discardableResult
    static func configure() -> String {
        for ref in refs {
            if let ref { UnregisterEventHotKey(ref) }
        }
        refs.removeAll()

        guard handlerInstalled else {
            status = "Atalhos globais indisponíveis"
            return status
        }

        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: "hotkeysEnabled") as? Bool ?? true
        guard enabled else {
            status = "Atalhos desativados"
            return status
        }

        let modifier: UInt32
        switch defaults.integer(forKey: "hotkeyModifiers") {
        case 1: modifier = UInt32(cmdKey | optionKey)
        case 2: modifier = UInt32(controlKey | shiftKey)
        default: modifier = UInt32(controlKey | optionKey)
        }

        let keys = [
            kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
            kVK_ANSI_C, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3
        ]

        var failures = 0
        for (index, key) in keys.enumerated() {
            var ref: EventHotKeyRef?
            let result = RegisterEventHotKey(
                UInt32(key), modifier,
                EventHotKeyID(signature: OSType(0x47424152), id: UInt32(index + 1)),
                GetApplicationEventTarget(), 0, &ref
            )
            if result == noErr {
                refs.append(ref)
            } else {
                failures += 1
            }
        }

        status = failures == 0
            ? "8 atalhos ativos"
            : "\(8 - failures)/8 atalhos ativos — verifique conflitos no macOS"
        return status
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
        .frame(height: 112)
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("GimbalBar").font(.title3.weight(.semibold))
                                Text("DJI Osmo Pocket 3")
                                    .font(.caption).foregroundStyle(.secondary)
                                HStack(spacing: 5) {
                                    Circle().fill(g.connected ? .green : .secondary).frame(width: 6, height: 6)
                                    Text(g.connected ? "Conectada" : "Desconectada")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("Horizontal \(Int(g.pan.rounded()))°")
                                Text("Vertical \(Int(g.tilt.rounded()))°")
                            }
                            .font(.system(.caption, design: .rounded).monospacedDigit())
                            .foregroundStyle(.secondary)
                        }
            Divider()
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                                    Label("Prévia ao vivo", systemImage: "video")
                                        .font(.subheadline.weight(.medium))
                                    Spacer()
                                    if !g.connected {
                                        Image(systemName: "video.slash")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                    
                                ZStack {
                                    Rectangle().fill(.black)
                                    PreviewView(session: preview.session)
                                    if !preview.status.isEmpty {
                                        Text(preview.status)
                                    .font(.caption)
                                    .foregroundStyle(.white)
                                    .multilineTextAlignment(.center)
                                    .padding(10)
                                    }
                                }
                                .frame(width: 288, height: 162) // 16:9 at the panel's content width; video views have no intrinsic size
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
                    
                                HStack {
                                    Label("Controle manual", systemImage: "move")
                                        .font(.subheadline.weight(.medium))
                                    Spacer()
                                    Text("Clique ou arraste")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                    
                                Pad(g: g).disabled(!g.connected)
                    
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
                                        Text("Passo").font(.caption).foregroundStyle(.secondary)
                                        Picker("Passo", selection: $g.step) {
                                            Text("5°").tag(5.0)
                                            Text("15°").tag(15.0)
                                            Text("30°").tag(30.0)
                                        }
                                        .pickerStyle(.segmented)
                                        .labelsHidden()
                    
                                        Button("Definir centro") { g.setHome() }
                                            .controlSize(.small)
                                        Toggle("Inverter horizontal", isOn: $g.invertPan)
                                            .toggleStyle(.checkbox)
                                            .controlSize(.small)
                                    }
                                }
                                .disabled(!g.connected)
                }
                .frame(width: 302)
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 9) {
                                    HStack {
                                        Label("Posições salvas", systemImage: "bookmark")
                                            .font(.subheadline.weight(.medium))
                                        Spacer()
                                        if g.isTransitioning {
                                            Button("Interromper") { g.stopTransition() }
                                                .controlSize(.small)
                                        }
                                    }
                    
                                    ForEach(1...3, id: \.self) { slot in
                                        let saved = g.savedPosition(slot: slot)
                                        HStack(spacing: 8) {
                                            Text("P\(slot)")
                                                .font(.system(.caption, design: .rounded).weight(.semibold))
                                                .frame(width: 24, alignment: .leading)
                                            if let saved {
                                                Text("\(Int(saved.pan.rounded()))° / \(Int(saved.tilt.rounded()))°")
                                                    .foregroundStyle(.secondary)
                                                    .font(.caption.monospacedDigit())
                                            } else {
                                                Text("Vazio").foregroundStyle(.tertiary).font(.caption)
                                            }
                                            Spacer(minLength: 4)
                                            Button("Salvar") { g.savePosition(slot: slot) }
                                                .disabled(!g.connected || g.isTransitioning)
                                                .controlSize(.small)
                                            Button("Ir") { g.recallPosition(slot: slot) }
                                                .disabled(!g.connected || saved == nil)
                                                .controlSize(.small)
                                        }
                                    }
                    
                                    HStack(spacing: 8) {
                                        Text("Movimentação").font(.caption).foregroundStyle(.secondary)
                                        Picker("Movimentação", selection: $g.presetMotionStep) {
                                            Text("Suave").tag(3.0)
                                            Text("Normal").tag(6.0)
                                            Text("Rápida").tag(9.0)
                                        }
                                        .pickerStyle(.segmented)
                                        .labelsHidden()
                                    }
                                    Text("Passos por software; não muda a velocidade dos motores")
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("Zoom da câmera", systemImage: "plus.magnifyingglass")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Text(String(format: "%.1f×", g.zoom))
                                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                .monospacedDigit()
                        }

                        HStack(spacing: 9) {
                            Slider(value: Binding(
                                get: { g.zoom },
                                set: { g.selectZoom($0) }
                            ), in: g.zoomMin...g.zoomMax, step: 0.1,
                                   onEditingChanged: { editing in
                                g.zoomEditingChanged(editing)
                            })
                            .disabled(!g.connected || !g.zoomAvailable)
                            Button("1×") { g.setZoom(g.zoomMin) }
                                .disabled(!g.connected || !g.zoomAvailable)
                                .controlSize(.small)
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(String(format: "Câmera: %.1f×", g.zoomActual))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Text(g.zoomStatus)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                                    Label("Atalhos de teclado", systemImage: "keyboard")
                                        .font(.subheadline.weight(.medium))
                    
                                    Toggle("Ativar atalhos globais", isOn: $g.hotkeysEnabled)
                                        .toggleStyle(.switch)
                                        .onChange(of: g.hotkeysEnabled) {
                                            g.hotkeyStatus = HotKeys.configure()
                                        }
                    
                                    Picker("Combinação", selection: $g.hotkeyModifiers) {
                                        Text("⌃⌥").tag(0)
                                        Text("⌘⌥").tag(1)
                                        Text("⌃⇧").tag(2)
                                    }
                                    .pickerStyle(.segmented)
                                    .disabled(!g.hotkeysEnabled)
                                    .onChange(of: g.hotkeyModifiers) {
                                        g.hotkeyStatus = HotKeys.configure()
                                    }
                    
                                    Text("\(g.shortcutPrefix) + setas: mover · C: centro · 1–3: posições")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(g.hotkeyStatus)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                    Spacer(minLength: 0)
                }
                .frame(width: 304, alignment: .leading)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            Divider()
            HStack {
                            Text("Versão 1.2 · Zoom nativo experimental")
                                .font(.caption2).foregroundStyle(.tertiary)
                            Spacer()
                            Button("Sair") { NSApp.terminate(nil) }
                                .buttonStyle(.plain)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
        }
        .padding(16)
        .frame(width: 690, height: 620)
        .onAppear {
            preview.start()
            g.hotkeyStatus = HotKeys.status
        }
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
        MenuBarExtra("Controle de câmera", systemImage: "camera.viewfinder") {
            Panel()
        }
        .menuBarExtraStyle(.window)
    }
}
