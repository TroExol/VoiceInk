import SwiftUI
import AppKit

@MainActor
final class EnhancementHUDManager {
    static let shared = EnhancementHUDManager()

    private let contentModel = EnhancementHUDContentModel()
    private var panel: NSPanel?
    private var hostingController: NSHostingController<EnhancementHUDView>?
    private var dismissTask: Task<Void, Never>?
    private weak var enhancementService: AIEnhancementService?
    private var observers: [NSObjectProtocol] = []

    private init() {}

    func configure(with enhancementService: AIEnhancementService) {
        self.enhancementService = enhancementService
        removeObservers()

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .enhancementToggleChanged, object: nil, queue: .main) { [weak self] _ in
                self?.presentCurrentState()
            },
            center.addObserver(forName: .promptSelectionChanged, object: nil, queue: .main) { [weak self] _ in
                self?.presentCurrentState()
            }
        ]
    }

    private func removeObservers() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        let hostingController = NSHostingController(rootView: EnhancementHUDView(model: contentModel))
        hostingController.view.wantsLayer = true

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: hostingController.view.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingController.view
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = true

        self.panel = panel
        self.hostingController = hostingController
    }

    private func presentCurrentState() {
        guard let enhancementService else { return }

        let isEnabled = enhancementService.isEnhancementEnabled
        let promptTitle = enhancementService.activePrompt?.title ?? "No prompt selected"

        presentHUD(isEnabled: isEnabled, promptTitle: promptTitle)
    }

    private func presentHUD(isEnabled: Bool, promptTitle: String) {
        ensurePanel()
        guard let panel, let hostingController else { return }

        contentModel.isEnabled = isEnabled
        contentModel.promptTitle = promptTitle
        hostingController.rootView = EnhancementHUDView(model: contentModel)

        hostingController.view.layoutSubtreeIfNeeded()
        let fittingSize = hostingController.view.fittingSize
        var frame = panel.frame
        frame.size = fittingSize
        panel.setFrame(frame, display: true)
        position(panel: panel, size: fittingSize)

        if panel.alphaValue == 0 {
            panel.alphaValue = 0
            panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        } else {
            panel.orderFront(nil)
        }

        scheduleDismissal()
    }

    private func scheduleDismissal() {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 2_200_000_000)
            } catch {
                return
            }
            guard let self else { return }
            self.dismiss()
        }
    }

    private func position(panel: NSPanel, size: CGSize) {
        let activeScreen = NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first!
        let screenFrame = activeScreen.visibleFrame

        let x = screenFrame.midX - (size.width / 2)
        let miniRecorderHeight: CGFloat = 40
        let basePadding: CGFloat = 24
        let spacing: CGFloat = 18
        let y = screenFrame.minY + basePadding + miniRecorderHeight + spacing

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func dismiss() {
        guard let panel else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.panel?.orderOut(nil)
            self?.dismissTask = nil
        }
    }
}

final class EnhancementHUDContentModel: ObservableObject {
    @Published var isEnabled = false
    @Published var promptTitle: String = "No prompt selected"
}

struct EnhancementHUDView: View {
    @ObservedObject var model: EnhancementHUDContentModel

    private var statusText: String {
        model.isEnabled ? "AI Enhancement On" : "AI Enhancement Off"
    }

    private var promptText: String {
        model.promptTitle.isEmpty ? "Prompt: None" : "Prompt: \(model.promptTitle)"
    }

    private var accentColor: Color {
        model.isEnabled ? .accentColor : Color.white.opacity(0.35)
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(accentColor.opacity(0.25))
                    .frame(width: 24, height: 24)

                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(statusText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)

                Text(promptText)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.75))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule(style: .continuous)
                .fill(.clear)
                .background(
                    ZStack {
                        Color.black.opacity(0.9)
                        LinearGradient(
                            colors: [
                                Color.black.opacity(0.95),
                                Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.9)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                            .opacity(0.05)
                    }
                    .clipShape(Capsule(style: .continuous))
                )
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5)
        )
        .fixedSize()
    }
}
