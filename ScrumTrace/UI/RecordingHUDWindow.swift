import SwiftUI
#if os(macOS)
import AppKit
#endif

struct HUDView: View {
    @ObservedObject var controller: SessionController

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(dotColor)
                .frame(width: 9, height: 9)
                .shadow(color: Color.red.opacity(isLiveRecording ? 0.8 : 0), radius: 6)
                .scaleEffect(isLiveRecording ? 1.15 : 1)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: isLiveRecording)
            Text(SessionController.clock(controller.mediaElapsed))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(red: 0.97, green: 0.93, blue: 0.86))
            Text("w \(SessionController.clock(controller.wallElapsed))")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(red: 0.97, green: 0.93, blue: 0.86).opacity(0.45))
            Divider().frame(height: 16)
            if controller.isBusy {
                Text(controller.statusLine)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(red: 0.97, green: 0.93, blue: 0.86).opacity(0.9))
                    .lineLimit(1)
            } else {
                hudButton("Shot", action: controller.openShot, enabled: controller.captureState.allowsNewCapture)
                hudButton("Pin", action: controller.pin, enabled: controller.captureState.allowsNewCapture)
                hudButton(
                    gatePaused ? "Resume" : "Pause",
                    action: controller.togglePause,
                    enabled: !gatePaused || controller.canResumeFromPause
                )
                hudButton("Stop", action: controller.stopRecording)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    }

    private var gatePaused: Bool {
        controller.captureState == .paused
    }

    private var isLiveRecording: Bool {
        controller.phase == .recording && !gatePaused
    }

    private var dotColor: Color {
        if controller.isBusy {
            return Color(red: 0.42, green: 0.62, blue: 0.88)
        }
        if gatePaused {
            return Color(red: 0.94, green: 0.64, blue: 0.22)
        }
        return Color(red: 0.89, green: 0.23, blue: 0.18)
    }

    private func hudButton(_ title: String, action: @escaping () -> Void, enabled: Bool = true) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color(red: 0.97, green: 0.93, blue: 0.86).opacity(enabled ? 0.9 : 0.35))
            .padding(.horizontal, 6)
            .disabled(!enabled)
            .allowsHitTesting(enabled)
    }
}

final class RecordingHUDWindow: NSPanel {
    private var hosting: NSHostingView<HUDView>?

    init(controller: SessionController) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 50),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        let view = NSHostingView(rootView: HUDView(controller: controller))
        view.frame = contentView?.bounds ?? .zero
        view.autoresizingMask = [.width, .height]
        contentView = view
        hosting = view
        orderOut(nil)
    }

    func setVisible(_ visible: Bool) {
        if visible {
            positionOnActiveScreen()
            orderFrontRegardless()
        } else {
            orderOut(nil)
        }
    }

    private func positionOnActiveScreen() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let size = NSSize(width: 580, height: 52)
        setFrame(
            NSRect(
                x: frame.midX - size.width / 2,
                y: frame.maxY - size.height - 18,
                width: size.width,
                height: size.height
            ),
            display: true
        )
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
