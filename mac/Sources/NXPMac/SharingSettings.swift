import SwiftUI
import NXPMacKit
import NXPMacModel
import NXPocketKit

/// Settings → Sharing: the switch, the folder, the address, the paired iPhones. Off by default; the line under the switch
/// says what turning it on does.
struct SharingGroup: View {
    @EnvironmentObject private var model: AppModel
    @State private var pairing = false
    @State private var confirmReset = false

    var body: some View {
        SettingsGroup(title: "Sharing") {
            SettingRow(symbol: "wifi", title: "Let paired iPhones download my built games",
                       detail: switchDetail, detailColor: failed ? Ink.bad : Ink.secondary, detailLines: 2) {
                Toggle("", isOn: Binding(get: { model.settings.value.shareEnabled },
                                         set: { model.settings.value.shareEnabled = $0 }))
                    .toggleStyle(.switch).labelsHidden()
            }
            if model.settings.value.shareEnabled {
                SettingRow(symbol: "folder", title: "Shared folder",
                           detail: model.settings.value.shareFolder.isEmpty ? "Same as Built games: \(Friendly.path(model.settings.value.outputURL.path))"
                                                                           : Friendly.path(model.settings.value.shareFolder),
                           detailLines: 2) {
                    if !model.settings.value.shareFolder.isEmpty {
                        Button("Reset") { model.settings.value.shareFolder = "" }.buttonStyle(QuietButtonStyle(large: true))
                    }
                    Button("Change") { model.chooseShareFolder() }.buttonStyle(QuietButtonStyle(large: true))
                }
                SettingRow(symbol: "square.and.arrow.down", title: "Accept copies of saves from iPhones",
                           detail: "Kept in \(Friendly.path(SaveBackup.root(in: model.settings.value.outputURL).path)), the last \(SaveBackup.keep) of each game.",
                           detailLines: 2) {
                    Toggle("", isOn: Binding(get: { model.settings.value.shareAcceptSaves },
                                             set: { model.settings.value.shareAcceptSaves = $0 }))
                        .toggleStyle(.switch).labelsHidden()
                }
                SettingRow(symbol: "hammer", title: "Let paired iPhones start builds of my games",
                           detail: "An iPhone can queue a game of the dump folder; it downloads it when it is built. A build takes up to an hour of this Mac and several GB of disk.",
                           detailLines: 3) {
                    Toggle("", isOn: Binding(get: { model.settings.value.shareAllowBuilds },
                                             set: { model.settings.value.shareAllowBuilds = $0 }))
                        .toggleStyle(.switch).labelsHidden()
                }
                if let address = model.sharingAddress {
                    SettingRow(symbol: "network", title: address,
                               detail: "Key \(model.sharingFingerprint). The iPhone shows the same when it pairs.", mono: true, detailLines: 2) {
                        Button("Pair an iPhone…") { model.beginPairing(); pairing = true }.buttonStyle(PrimaryButtonStyle())
                    }
                }
                ForEach(model.pairedDevices) { device in
                    SettingRow(symbol: "iphone", tint: Ink.good, title: device.name,
                               detail: "Paired \(device.pairedAt.formatted(date: .abbreviated, time: .omitted)) · seen \(device.lastSeen.formatted(.relative(presentation: .named)))") {
                        Button("Revoke") { model.revokeDevice(device) }.buttonStyle(QuietButtonStyle(large: true))
                    }
                }
                if !model.pairedDevices.isEmpty {
                    SettingRow(symbol: "key.slash", tint: Ink.secondary, title: "Forget every paired iPhone",
                               detail: "Makes a new key: every iPhone has to pair again.") {
                        Button("Reset…") { confirmReset = true }.buttonStyle(QuietButtonStyle(large: true))
                    }
                }
            }
        }
        .sheet(isPresented: $pairing, onDismiss: { model.cancelPairing() }) { PairingSheet(isShown: $pairing) }
        .confirmationDialog("Make a new key?", isPresented: $confirmReset) {
            Button("Reset and forget every iPhone", role: .destructive) { model.resetSharing() }
        } message: {
            Text("Every paired iPhone stops working until it is paired again. Nothing on the iPhones is deleted.")
        }
    }

    private var failed: Bool {
        if case .failed = model.sharing { return true }
        return false
    }

    private var switchDetail: String {
        switch model.sharing {
        case .off:
            return model.settings.value.shareEnabled ? "Starting…"
                : "Off: nothing listens on this Mac. When on, your built games are shared read-only, on this network only, with iPhones you paired."
        case .starting:
            return "Starting…"
        case .listening:
            let active = model.sharingConnections
            return "On. Read-only, on this network only, for the iPhones below. Allow the firewall prompt the first time."
                + (active > 0 ? " \(active) connected." : "")
        case .failed(let reason):
            return "Could not start: \(reason)"
        }
    }
}

/// How an iPhone is paired: the QR code first, a number to compare when it cannot be scanned, the typed code last. All
/// three are good for the same two minutes and the same one iPhone.
struct PairingSheet: View {
    @EnvironmentObject private var model: AppModel
    @Binding var isShown: Bool

    var body: some View {
        VStack(spacing: 18) {
            PageTitle(title: "Pair an iPhone", size: 28,
                      subtitle: "Same network. It works once, for two minutes.")
            if let offer = model.pairingOffer {
                if let request = model.pairRequest {
                    comparison(request)
                } else {
                    scan(offer)
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = max(Int(offer.expires.timeIntervalSince(context.date)), 0)
                    Text("Waiting for the iPhone · \(left / 60):\(String(format: "%02d", left % 60)) left")
                        .font(.system(size: 13)).foregroundStyle(Ink.secondary)
                }
            } else {
                Text("Done, or the time ran out.").font(.system(size: 14)).foregroundStyle(Ink.secondary)
            }
            HStack {
                Spacer()
                Button(model.pairingOffer == nil ? "Close" : "Cancel") { isShown = false }
                    .buttonStyle(PrimaryButtonStyle(large: true)).keyboardShortcut(model.pairRequest == nil ? .defaultAction : .cancelAction)
            }
        }
        .padding(28)
        .frame(width: 520)
        .background(Ink.background)
        .onChange(of: model.pairingOffer) { offer in if offer == nil { isShown = false } }
    }

    private func scan(_ offer: PairingSessions.Offer) -> some View {
        VStack(spacing: 14) {
            if let link = model.pairingLink {
                QRCode(text: link.absoluteString)
                    .frame(width: 200, height: 200).padding(14)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                Text("Scan it with the iPhone's Camera, then open the link it shows.")
                    .font(.system(size: 13)).foregroundStyle(Ink.secondary)
            }
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    Text("On the iPhone: Settings → Sources → Add a source → Mac, then \"Compare a number\", or type this code.")
                        .font(.system(size: 12)).foregroundStyle(Ink.secondary)
                    Text(offer.code)
                        .font(.system(size: 32, weight: .bold, design: .monospaced)).kerning(2)
                        .foregroundStyle(Ink.primary).textSelection(.enabled)
                    Text("The key on the iPhone must read \(model.sharingFingerprint.prefix(9))…")
                        .font(.system(size: 12)).foregroundStyle(Ink.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            } label: {
                Text("Cannot scan?").font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.primary)
            }
            .padding(14)
            .background(Ink.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func comparison(_ request: PairingSessions.Request) -> some View {
        VStack(spacing: 12) {
            Text("\(request.name) wants to pair").font(.system(size: 15, weight: .medium)).foregroundStyle(Ink.primary)
            if let number = request.number {
                Text(number)
                    .font(.system(size: 48, weight: .bold, design: .monospaced)).kerning(3).foregroundStyle(Ink.primary)
                    .padding(.vertical, 12).padding(.horizontal, 28)
                    .background(Ink.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                Text("Allow it only if the iPhone shows the same number.")
                    .font(.system(size: 13)).foregroundStyle(Ink.secondary)
                HStack(spacing: 10) {
                    Button("Refuse") { model.refusePairRequest() }.buttonStyle(QuietButtonStyle(large: true))
                    Button("Allow") { model.allowPairRequest() }.buttonStyle(PrimaryButtonStyle(large: true))
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                ProgressView().controlSize(.small)
                Text("Waiting for its number…").font(.system(size: 13)).foregroundStyle(Ink.secondary)
            }
        }
        .frame(maxWidth: .infinity).padding(18)
        .background(Ink.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
