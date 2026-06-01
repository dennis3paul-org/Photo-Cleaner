import Photos
import SwiftUI

struct ContentView: View {
    @StateObject private var photoService = PhotoLibraryService()
    @StateObject private var appModel = AppModel()

    var body: some View {
        Group {
            switch photoService.authorizationStatus {
            case .notDetermined:
                PermissionRequestView()
            case .restricted, .denied:
                PermissionDeniedView()
            case .authorized, .limited:
                phaseView
            @unknown default:
                PermissionDeniedView()
            }
        }
        .environmentObject(photoService)
        .environmentObject(appModel)
        .task {
            if photoService.authorizationStatus == .notDetermined {
                await photoService.requestAuthorization()
            }
        }
    }

    @ViewBuilder
    private var phaseView: some View {
        switch appModel.phase {
        case .idle:
            IdleView()
        case .pickBatch:
            PickBatchView()
        case .triage:
            TriageView()
        case .cleanup:
            LocalCleanupView()
        case .googlePhotos, .googleSwipe, .googleCleanup:
            // All three GP phases route to the same view so the WebView (and
            // its WIZ tokens) stays alive across triage and cleanup. The view
            // renders overlays based on the active phase.
            GooglePhotosView()
        case .done:
            IdleView()
        }
    }
}

private struct PermissionRequestView: View {
    @EnvironmentObject var photoService: PhotoLibraryService

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 72))
                .foregroundStyle(.tint)
            Text("Photo Cleaner")
                .font(.largeTitle.bold())
            Text("Review and delete photos one swipe at a time.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                Task { await photoService.requestAuthorization() }
            } label: {
                Text("Grant Photo Access")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
    }
}

private struct PermissionDeniedView: View {
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "lock.shield")
                .font(.system(size: 72))
                .foregroundStyle(.secondary)
            Text("Access Denied")
                .font(.title.bold())
            Text("Photo Cleaner needs access to your photo library. You can enable it in Settings.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("Open Settings")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
    }
}

#Preview {
    ContentView()
}
