import NXPocketKit
import NXShellUI
import SwiftUI

/// A web library: the address of a folder the launcher's *Export for the web* made, put behind https. The address may be the secret; an
/// access token is optional. The source is tried before it is kept, so a wrong address is said at once.
struct WebSheet: View {
    @EnvironmentObject private var model: ShellHostModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var sources: NetworkSources
    @State private var name = ""
    @State private var address = ""
    @State private var token = ""
    @State private var busy = false
    @State private var message: String?
    @State private var found: Int?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(model.text(.addWebLibrary)).font(ShellFont.display(24)).foregroundStyle(ShellInk.primary).padding(.top, 20)
                Text(model.text(.webLibraryBody)).font(.system(size: 13)).foregroundStyle(ShellInk.secondary).lineSpacing(2)
                TextField(model.text(.sourceNameLabel), text: $name).textFieldStyle(.roundedBorder)
                TextField("https://", text: $address)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).textFieldStyle(.roundedBorder)
                SecureField(model.text(.webTokenLabel), text: $token).textFieldStyle(.roundedBorder)
                if let found {
                    Label(String(format: model.text(.webLibraryFound), found), systemImage: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(ShellInk.good)
                    Button(model.text(.sourceSave)) { save() }.buttonStyle(ShellButtonStyle(prominent: true))
                } else {
                    Button(model.text(.webLibraryCheck)) { check() }.buttonStyle(ShellButtonStyle(prominent: true)).disabled(busy || address.isEmpty)
                }
                if busy { ProgressView() }
                if let message { Text(message).font(.system(size: 13)).foregroundStyle(ShellInk.bad) }
                Button(model.text(.close)) { dismiss() }.buttonStyle(ShellButtonStyle()).padding(.top, 8)
            }
            .padding(.horizontal, 20)
        }
        .onChange(of: address) { _, _ in found = nil }
        .onChange(of: token) { _, _ in found = nil }
    }

    private func check() {
        guard let url = WebSource.validated(address) else { message = model.text(.archiveBadLink); return }
        busy = true
        message = nil
        Task {
            defer { busy = false }
            do {
                found = try await WebSource(baseURL: url, token: token).games().count
            } catch {
                found = nil
                message = model.sourceMessage(NetworkSources.reason(error))
            }
        }
    }

    private func save() {
        guard let url = WebSource.validated(address) else { return }
        _ = sources.saveWeb(url: url, token: token, name: name)
        dismiss()
    }
}
