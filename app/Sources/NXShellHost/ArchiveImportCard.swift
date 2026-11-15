import NXShellUI
import SwiftUI
import UniformTypeIdentifiers

/// A file read in place: the picker hands over a security-scoped URL, and the shell reads the archive where it is. A build is
/// gigabytes, so it is never copied first (`DocumentPicker`, which copies, is for the small file of a certificate).
struct ArchivePicker: UIViewControllerRepresentable {
    var types: [UTType] = [.item]
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: ArchivePicker
        init(_ parent: ArchivePicker) { self.parent = parent }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { parent.onPick(url) } else { parent.onCancel() }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { parent.onCancel() }
    }
}

/// The library's plus button: everything that brings a game in. A build the player already has (an archive from Files or a link only
/// they know, a folder), and the sources it comes from (the Mac, a server). Each import begins with the warning (`ArchiveRequestAlert`).
struct ImportMenu: View {
    @EnvironmentObject private var model: ShellHostModel
    @State private var picking = false
    @State private var pickingFolder = false
    @State private var asking = false
    @State private var link = ""
    @State private var linkHash = ""
    @State private var sheet: SourcesCard.AddSourceSheet?

    var body: some View {
        Menu {
            Section(model.text(.importSection)) {
                Button { picking = true } label: { Label(model.text(.importArchiveItem), systemImage: "doc.zipper") }
                Button { pickingFolder = true } label: { Label(model.text(.importFolderItem), systemImage: "folder") }
                Button { link = ""; linkHash = ""; asking = true } label: { Label(model.text(.importLinkItem), systemImage: "link") }
            }
            .disabled(model.importState.isRunning)
            Section(model.text(.sourcesSection)) {
                Button { open(.discover) } label: { Label(model.text(.findMyMac), systemImage: "desktopcomputer") }
                Button { open(.address) } label: { Label(model.text(.addMacByAddress), systemImage: "number") }
                Button { open(.sftp) } label: { Label(model.text(.addSFTPServer), systemImage: "externaldrive.connected.to.line.below") }
                Button { open(.web) } label: { Label(model.text(.addWebLibrary), systemImage: "globe") }
            }
        } label: {
            Image(systemName: "plus").font(.system(size: 17, weight: .semibold)).foregroundStyle(ShellInk.onDeep)
                .frame(width: 42, height: 42).background(ShellInk.accent, in: Circle())
        }
        .accessibilityLabel(model.text(.addGames))
        .sheet(isPresented: $picking) {
            ArchivePicker(onPick: { url in
                picking = false
                // The warning waits for the picker to be gone: an alert asked for while a sheet closes is dropped.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { model.archiveRequest = ArchiveRequest(url: url, isFolder: false) }
            }, onCancel: { picking = false })
                .ignoresSafeArea()
        }
        .sheet(isPresented: $pickingFolder) {
            ArchivePicker(types: [.folder], onPick: { url in
                pickingFolder = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { model.archiveRequest = ArchiveRequest(url: url, isFolder: true) }
            }, onCancel: { pickingFolder = false })
                .ignoresSafeArea()
        }
        .sheet(item: $sheet) { which in
            Group {
                switch which {
                case .discover: DiscoverySheet(sources: model.sources)
                case .address: PairSheet(sources: model.sources, address: "", contactOnAppear: false)
                case .sftp: SFTPSheet(sources: model.sources)
                case .web: WebSheet(sources: model.sources)
                }
            }
            .environmentObject(model)
            .presentationBackground(ShellInk.background)
            .preferredColorScheme(.dark)
        }
        .alert(model.text(.archiveLinkTitle), isPresented: $asking) {
            TextField("https://", text: $link).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            TextField(model.text(.archiveHashPlaceholder), text: $linkHash).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button(model.text(.archiveImportAction)) { model.importArchive(fromLink: link, expectedSHA256: linkHash); link = ""; linkHash = "" }
            Button(model.text(.cancel), role: .cancel) { link = ""; linkHash = "" }
        } message: {
            Text("\(model.text(.archiveLinkHint))\n\n\(model.text(.archiveWarning))")
        }
    }

    /// Choosing to add a source is the player's own word that network sources are wanted: they are turned on with it.
    private func open(_ which: SourcesCard.AddSourceSheet) {
        if !model.sources.enabled { model.sources.enabled = true }
        sheet = which
    }
}

/// The warning every import begins with, with the hash the player may give: for a file picked in Files, a folder, or an archive sent by
/// AirDrop. Nothing is imported until the player says so here.
struct ArchiveRequestAlert: ViewModifier {
    @EnvironmentObject private var model: ShellHostModel
    @State private var hash = ""

    func body(content: Content) -> some View {
        content.background {
            Color.clear.alert(model.text(.archiveWarningTitle), isPresented: Binding(get: { model.archiveRequest != nil }, set: { if !$0 { model.archiveRequest = nil } }),
                              presenting: model.archiveRequest) { request in
                if !request.isFolder {
                    TextField(model.text(.archiveHashPlaceholder), text: $hash).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Button(model.text(.archiveImportAction)) {
                    if request.isFolder { model.importFolder(at: request.url) } else { model.importArchive(at: request.url, expectedSHA256: hash) }
                    hash = ""
                }
                Button(model.text(.cancel), role: .cancel) { hash = "" }
            } message: { request in
                Text(request.isFolder ? model.text(.archiveWarning) : "\(model.text(.archiveWarning))\n\n\(model.text(.archiveHashHint))")
            }
        }
    }
}
