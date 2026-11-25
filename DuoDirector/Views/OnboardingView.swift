import SwiftUI
import AVFoundation
import UIKit

// =====================================================================================
//  OnboardingView (Phase 10): first launch
//
//  Three short pages, then camera + mic permission is asked IN CONTEXT (after the user
//  has read why), instead of system prompts appearing over a black screen at launch.
//  CaptureRootView doesn't start the camera until this is done. UI tests skip it.
//  If access was denied, the same view offers a button to Settings.
// =====================================================================================

enum Onboarding {
    static let completedKey = "onboarding.completed.v1"
    static var isCompleted: Bool {
        get { UserDefaults.standard.bool(forKey: completedKey) }
        set { UserDefaults.standard.set(newValue, forKey: completedKey) }
    }
}

struct OnboardingView: View {
    var onFinish: () -> Void
    @State private var page = 0

    private struct Page: Identifiable {
        let id: Int
        let symbol: String
        let title: LocalizedStringKey
        let body: LocalizedStringKey
    }

    private let pages: [Page] = [
        Page(id: 0, symbol: "film.stack", title: "Welcome to DuoDirector",
             body: "A studio for iPhone Duo: shoot with the rear camera while the cover display shows you the shot."),
        Page(id: 1, symbol: "rectangle.portrait.on.rectangle.portrait", title: "Use every posture",
             body: "Open it flat to direct, stand it in tabletop for a producer deck, or record yourself and a guest with Dual-Cam."),
        Page(id: 2, symbol: "lock.shield", title: "Your videos stay yours",
             body: "Takes are saved on this phone and, if you turn it on, in your own iCloud. Nothing is sent to us."),
    ]

    var body: some View {
        VStack(spacing: 24) {
            TabView(selection: $page) {
                ForEach(pages) { p in
                    VStack(spacing: 20) {
                        Image(systemName: p.symbol).font(.system(size: 64)).foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        Text(p.title).font(.largeTitle.bold()).multilineTextAlignment(.center)
                        Text(p.body).font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 32)
                    .tag(p.id)
                }
                permissionsPage.tag(pages.count)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private var permissionsPage: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.aperture").font(.system(size: 64)).foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Camera and microphone").font(.largeTitle.bold()).multilineTextAlignment(.center)
            Text("DuoDirector needs the camera to record and the microphone for sound and live levels. You'll be asked next.")
                .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button {
                Task {
                    _ = await CaptureSessionController.requestAccess()
                    Onboarding.isCompleted = true
                    onFinish()
                }
            } label: {
                Text("Continue").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 12)
        }
        .padding(.horizontal, 32)
    }
}

/// Shown in place of the viewfinder when camera or mic access is off.
struct PermissionDeniedView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Camera access is off", systemImage: "video.slash")
        } description: {
            Text("Turn on Camera and Microphone for DuoDirector in Settings to record.")
        } actions: {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
