import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Notifications page (v0.12): provider status + self-host Firebase (FCM) setup.
/// micaGO provides no cloud — each user brings their own Firebase project.
struct NotificationsPage: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            ProviderStatusCard()
            FirebaseSetupCard()
            PushPrivacyCard()
        }
        .task { await model.refresh() }
    }
}

private struct ProviderStatusCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        SectionCard(title: "Provider Status") {
            if let n = model.status?.notifications {
                LabeledRow(label: "State", value: stateLabel(n))
                LabeledRow(label: "Enabled", value: n.enabled ? String(localized: "yes") : String(localized: "no"))
                LabeledRow(label: "Provider", value: n.provider)
                LabeledRow(label: "Client config", value: (n.fcmClientConfigured ?? false) ? String(localized: "configured") : String(localized: "not set"))
                LabeledRow(label: "Service account", value: (n.fcmServiceAccountConfigured ?? false) ? String(localized: "configured") : String(localized: "not set"))
                LabeledRow(label: "Implemented", value: n.implemented.joined(separator: ", "))
                LabeledRow(label: "Stub", value: n.stub.isEmpty ? "—" : n.stub.joined(separator: ", "))
                LabeledRow(label: "Firestore URL sync", value: model.firestoreSyncActive ? String(localized: "enabled") : String(localized: "disabled"))
            } else {
                Text("Start the server to read notification status.").foregroundStyle(.secondary)
            }
        }
    }

    private func stateLabel(_ n: NotificationStatus) -> String {
        if !n.enabled { return String(localized: "disabled") }
        if n.provider == "fcm" { return n.implemented.contains("fcm") ? String(localized: "configured (fcm)") : String(localized: "config invalid (fcm)") }
        return String(localized: "active (\(n.provider))")
    }
}

private struct FirebaseSetupCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        SectionCard(title: "Firebase Self-Host (Android FCM)") {
            Toggle("Notifications enabled", isOn: $model.notifEnabled)
            Toggle("Enable FCM delivery", isOn: $model.fcmEnabled)
                .onChange(of: model.fcmEnabled) { enabled in
                    if enabled { model.notifEnabled = true }
                }

            // C60: what a push may reveal. "Sender & message" is what makes the
            // phone show the actual text; the payload travels through FCM.
            Picker("Notification preview", selection: $model.notifPreview) {
                Text("Sender & message").tag("sender_and_text")
                Text("Sender only").tag("sender")
                Text("None (silent wake)").tag("none")
            }
            .pickerStyle(.menu)
            Text("“Sender & message” puts the message text in the push, which goes through Google FCM. Pick “Sender only” or “None” to keep message text off Google's servers.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            firebaseFileRow(
                icon: "iphone.gen3.radiowaves.left.and.right",
                ready: googleServicesReady,
                title: googleServicesLabel,
                button: "Choose google-services.json…",
                action: chooseGoogleServices
            )
            Text("The Android app uses this file to set up Firebase.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            firebaseFileRow(
                icon: "key.horizontal.fill",
                ready: serviceAccountReady,
                title: serviceAccountLabel,
                button: "Choose service-account JSON…",
                action: chooseServiceAccount
            )
            Text("This file stays on the Mac. The server uses it to send pushes.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Firebase project ID (optional)", text: $model.fcmProjectID)
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))

            Toggle("Sync public URL to Firestore (optional)", isOn: $model.firestoreURLSync)
            Text("Only the public server URL is written there. Messages, tokens, contacts, and attachments are never stored.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button("Save") { Task { await model.saveNotificationsConfig() } }
                    .disabled(model.notifBusy)
                Button("Send test notification") { Task { await model.testAllPushDevices() } }
                    .disabled(model.notifBusy || !model.fcmEnabled)
                Button("Clear Firebase config", role: .destructive) { Task { await model.clearNotificationsConfig() } }
                    .disabled(model.notifBusy)
                if model.notifBusy { ProgressView().controlSize(.small) }
            }

            if let result = model.notifResult {
                Text(result).font(.caption)
                    .foregroundStyle(result.hasPrefix("Saved") || result.contains("sent") ? .green : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Sends a test to every registered FCM device.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var serviceAccountReady: Bool {
        !model.serviceAccountPath.isEmpty || (model.status?.notifications.fcmServiceAccountConfigured ?? false)
    }

    private var googleServicesReady: Bool {
        !model.googleServicesPath.isEmpty || (model.status?.notifications.fcmClientConfigured ?? false)
    }

    private var serviceAccountLabel: String {
        if model.serviceAccountPath.isEmpty {
            return serviceAccountReady ? String(localized: "Service account already configured") : String(localized: "No service-account file selected")
        }
        return String(localized: "Selected: \((model.serviceAccountPath as NSString).lastPathComponent)")
    }

    private var googleServicesLabel: String {
        if model.googleServicesPath.isEmpty {
            return googleServicesReady ? String(localized: "google-services.json already configured") : String(localized: "No google-services.json selected")
        }
        return String(localized: "Selected: \((model.googleServicesPath as NSString).lastPathComponent)")
    }

    private func firebaseFileRow(icon: String, ready: Bool, title: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ready ? "checkmark.seal.fill" : icon)
                .foregroundStyle(ready ? Color.green : Color.secondary)
            Text(title)
                .font(.callout).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button(LocalizedStringKey(button)) { action() }
        }
    }

    private func chooseServiceAccount() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            model.serviceAccountPath = url.path
        }
    }

    private func chooseGoogleServices() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            model.googleServicesPath = url.path
        }
    }
}

private struct PushPrivacyCard: View {
    var body: some View {
        SectionCard(title: "Push Privacy") {
            Text("""
            • micaGO has no cloud server. You use your own Firebase project.
            • Firebase is only used for Android push and the optional public URL lookup.
            • Windows clients get notifications over WebSocket while they run. Huawei/HarmonyOS push isn't supported yet, and iOS push isn't planned.
            • Firebase never stores message content, contacts, phone numbers, tokens, attachments, chat history, the device list, or sync rules.
            • A push only carries delivery data. Message history still syncs over your normal micaGO connection.
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Link("Firebase Console", destination: URL(string: "https://console.firebase.google.com")!)
            Link("Firebase setup guide", destination: URL(string: "https://github.com/cinmou/MicaGo/blob/main/docs/setup/firebase/README.md")!)
                .font(.caption2)
        }
    }
}
