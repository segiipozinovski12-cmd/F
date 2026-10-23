import SwiftUI
import SceneKit

struct ArtifactSceneControls: Equatable {
    var yaw: Float = 0
    var pitch: Float = 0
    var distance: Float = 7.4
    var automatic = true
    var lighting = 0
    var reset = 0
}

private struct ArtifactSceneSurface: UIViewRepresentable {
    var collection: String
    var model: String?
    var active: Bool
    var interactive: Bool
    var motion: Bool
    @Binding var controls: ArtifactSceneControls

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero); view.backgroundColor = .clear; view.isOpaque = false
        view.antialiasingMode = .multisampling4X; view.autoenablesDefaultLighting = false
        view.rendersContinuously = false; view.preferredFramesPerSecond = ProcessInfo.processInfo.isLowPowerModeEnabled ? 15 : 30
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:)))
        view.addGestureRecognizer(pan); view.addGestureRecognizer(pinch)
        view.accessibilityElementsHidden = true
        return view
    }
    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.parent = self
        let key = collection + ":" + (model ?? "original")
        if context.coordinator.key != key {
            view.scene = ArtifactSceneFactory.scene(collection: collection, model: model)
            view.pointOfView = view.scene?.rootNode.childNode(withName: "camera", recursively: false)
            context.coordinator.key = key
        }
        view.preferredFramesPerSecond = ProcessInfo.processInfo.isLowPowerModeEnabled ? 15 : 30
        view.isUserInteractionEnabled = interactive
        let orbit = view.scene?.rootNode.childNode(withName: "orbit", recursively: false)
        let floating = orbit?.childNode(withName: "float", recursively: false)
        let previous = context.coordinator.applied
        let turning = orbit?.action(forKey: "turn") != nil
        let reset = previous?.reset != controls.reset
        let changed = previous?.yaw != controls.yaw || previous?.pitch != controls.pitch
        let adjusting = view.gestureRecognizers?.contains { $0.state == .began || $0.state == .changed } == true
        SCNTransaction.begin(); SCNTransaction.animationDuration = motion && !adjusting && active ? 0.22 : 0
        if reset {
            orbit?.removeAction(forKey: "turn"); orbit?.eulerAngles = SCNVector3(controls.pitch, controls.yaw, 0)
        } else if changed {
            let current = orbit?.presentation.eulerAngles ?? SCNVector3Zero
            orbit?.removeAction(forKey: "turn")
            orbit?.eulerAngles = SCNVector3(controls.pitch, current.y + controls.yaw - (previous?.yaw ?? 0), 0)
        } else if turning && (!active || !motion || !controls.automatic) {
            let current = orbit?.presentation.eulerAngles ?? SCNVector3Zero
            orbit?.removeAction(forKey: "turn"); orbit?.eulerAngles = current
        }
        view.pointOfView?.position.z = controls.distance
        SCNTransaction.commit()
        let animate = active && motion && controls.automatic && !ProcessInfo.processInfo.isLowPowerModeEnabled
        if animate && orbit?.action(forKey: "turn") == nil {
            orbit?.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 32)), forKey: "turn")
            let up = SCNAction.moveBy(x: 0, y: 0.065, z: 0, duration: 2.4); up.timingMode = .easeInEaseOut
            floating?.runAction(.repeatForever(.sequence([up, up.reversed()])), forKey: "float")
        } else if !animate {
            orbit?.removeAction(forKey: "turn"); floating?.removeAction(forKey: "float"); floating?.position.y = 0
        }
        for name in ["key", "fill", "rim"] {
            let light = view.scene?.rootNode.childNode(withName: name, recursively: false)?.light
            let base: CGFloat = name == "key" ? 1100 : (name == "rim" ? 1500 : 420)
            light?.intensity = base * (controls.lighting == 1 ? (name == "fill" ? 0.2 : 1.2) : (controls.lighting == 2 ? 0.72 : 1))
        }
        view.scene?.lightingEnvironment.intensity = controls.lighting == 1 ? 0.45 : (controls.lighting == 2 ? 1.7 : 1.1)
        context.coordinator.applied = controls
        view.isPlaying = animate
        view.setNeedsDisplay()
    }
    static func dismantleUIView(_ view: SCNView, coordinator: Coordinator) {
        view.isPlaying = false; view.scene?.rootNode.enumerateChildNodes { node, _ in node.removeAllActions() }; view.scene = nil
    }
    final class Coordinator: NSObject {
        var parent: ArtifactSceneSurface
        var key = ""
        var applied: ArtifactSceneControls?
        private var start = ArtifactSceneControls()
        init(_ parent: ArtifactSceneSurface) { self.parent = parent }
        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            if gesture.state == .began {
                if let view = gesture.view as? SCNView, let orbit = view.scene?.rootNode.childNode(withName: "orbit", recursively: false) {
                    let current = orbit.presentation.eulerAngles
                    orbit.removeAction(forKey: "turn"); orbit.eulerAngles = current
                    parent.controls.yaw = current.y; applied?.yaw = current.y
                }
                parent.controls.automatic = false; start = parent.controls
            }
            let delta = gesture.translation(in: gesture.view)
            parent.controls.yaw = start.yaw + Float(delta.x) * 0.009
            parent.controls.pitch = min(1.05, max(-1.05, start.pitch + Float(delta.y) * 0.007))
        }
        @objc func pinch(_ gesture: UIPinchGestureRecognizer) {
            if gesture.state == .began { start = parent.controls }
            parent.controls.distance = min(10, max(4.5, start.distance / Float(gesture.scale)))
        }
    }
}

/// One live scene per visible hero. Grids use cached renders of the same models.
struct ArtifactHero: View {
    var collection: String
    var traits: ArtifactTraits?
    var active = true
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var controls = ArtifactSceneControls()
    var body: some View {
        ArtifactBackdrop(collection: collection, traits: traits)
            .overlay {
                ArtifactSceneSurface(collection: collection, model: traits?.model.id, active: active && visible && scenePhase == .active,
                                     interactive: false, motion: !reduceMotion && !lowPower, controls: $controls).allowsHitTesting(false)
            }
            .aspectRatio(1, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .onAppear { visible = true }.onDisappear { visible = false }
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled }
            .accessibilityLabel("Объёмный артефакт \(ArtifactCollection.titles[collection] ?? collection), \(traits?.model.title ?? "Original")")
    }
}

struct ArtifactInspectionView: View {
    var collection: String
    var traits: ArtifactTraits? = nil
    var number: String? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var controls = ArtifactSceneControls()
    private let lightNames = ["Студия", "Контраст", "Мягкий"]

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("OBJECT / VO1D").font(.caption2.monospaced()).tracking(3).foregroundStyle(.secondary)
                        Text(ArtifactCollection.titles[collection] ?? collection).font(.title.bold())
                    }
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark").font(.headline).frame(width: 48, height: 48).background(.white.opacity(0.08), in: Circle()) }
                        .accessibilityLabel("Закрыть осмотр").buttonStyle(MotionButtonStyle())
                }
                ZStack(alignment: .bottom) {
                    ArtifactBackdrop(collection: collection, traits: traits)
                    ArtifactSceneSurface(collection: collection, model: traits?.model.id, active: visible && scenePhase == .active,
                                         interactive: true, motion: !reduceMotion && !lowPower, controls: $controls)
                    HStack {
                        Text(traits?.model.title ?? "Original").font(.caption.bold())
                        Spacer()
                        if let number { Text(number).font(.caption.monospaced()) }
                        else { Text("ПРЕДПРОСМОТР").font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1) }
                    }.padding(18).background(LinearGradient(colors: [.clear, .black.opacity(0.4)], startPoint: .top, endPoint: .bottom)).allowsHitTesting(false)
                }
                .frame(height: max(180, min(geometry.size.width - 40, geometry.size.height - 280)))
                .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("3D-осмотр \(traits?.model.title ?? "Original")")
                .accessibilityHint("Используй кнопки поворота и масштаба ниже")
                Text("Вращай пальцем · приближай двумя").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    control("arrow.counterclockwise", label: "Повернуть влево") { controls.automatic = false; controls.yaw -= .pi / 6 }
                    control("arrow.clockwise", label: "Повернуть вправо") { controls.automatic = false; controls.yaw += .pi / 6 }
                    control("minus.magnifyingglass", label: "Отдалить") { controls.distance = min(10, controls.distance + 0.7) }
                    control("plus.magnifyingglass", label: "Приблизить") { controls.distance = max(4.5, controls.distance - 0.7) }
                }
                HStack(spacing: 10) {
                    Button { controls.automatic.toggle() } label: { Label("Вращение", systemImage: controls.automatic && !reduceMotion ? "pause.fill" : "play.fill").font(.caption.bold()).frame(maxWidth: .infinity, minHeight: 46).background(.white.opacity(0.07), in: Capsule()) }
                        .disabled(reduceMotion || lowPower)
                    Button { controls.lighting = (controls.lighting + 1) % 3 } label: { Label(lightNames[controls.lighting], systemImage: "lightbulb").font(.caption.bold()).frame(maxWidth: .infinity, minHeight: 46).background(.white.opacity(0.07), in: Capsule()) }
                        .accessibilityLabel("Свет: \(lightNames[controls.lighting]). Изменить")
                }.buttonStyle(MotionButtonStyle())
                Button("Вернуть исходный вид") { controls = ArtifactSceneControls(reset: controls.reset + 1) }.font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
                Spacer(minLength: 0)
            }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }.background { VoidBackground() }.preferredColorScheme(.dark)
            .onAppear { visible = true }.onDisappear { visible = false }
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled }
    }
    private func control(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.title3).frame(maxWidth: .infinity, minHeight: 48).background(.white.opacity(0.07), in: Capsule()) }
            .accessibilityLabel(label).buttonStyle(MotionButtonStyle())
    }
}
