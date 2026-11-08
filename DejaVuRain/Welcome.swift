import AppKit
import SwiftUI

private struct WelcomeView: View {
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "cloud.rain")
                .font(.system(size: 46))
                .foregroundStyle(Color(red: 0, green: 1, blue: 0.255))
            Text("Welcome to Déjà Vu Rain")
                .font(.title2.bold())
            Text("Déjà Vu Rain turns your desktop background into falling digital rain.")
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 8) {
                Label("Find it in the menu bar, at the rain-cloud icon. There is no Dock icon.", systemImage: "menubar.rectangle")
                Label("The rain sits behind your windows and desktop icons. Move or minimize windows to see it.", systemImage: "macwindow")
                Label("Choose the color, speed, density, brightness and displays from the menu.", systemImage: "slider.horizontal.3")
                Label("Press ⌃⌥⌘R anywhere to pause or resume.", systemImage: "keyboard")
                Label("It pauses by itself when the screen sleeps or locks, and can pause on battery.", systemImage: "battery.75percent")
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            Button("Get Started", action: onClose)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
        .padding(28)
        .frame(width: 460)
    }
}

@MainActor
final class WelcomeWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: WelcomeView { [weak self] in self?.window?.close() })
            let w = NSWindow(contentViewController: hosting)
            w.title = "Welcome to Déjà Vu Rain"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
