import SwiftUI
import CoreImage.CIFilterBuiltins

/// Invite (board 12b): your one code on a print card, three ways to send it, and what happened to
/// the ones you sent. The counts and the rules are the App Store invite sheet's (`InviteCopy`).
struct V2InviteView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.v2Palette) private var palette
    @Environment(AuthService.self) private var auth

    @State private var quota: AuthService.InviteQuota = .unknown
    @State private var sent: [AuthService.SentInvite] = []
    @State private var copied = false
    @State private var showQR = false

    private var code: String? {
        #if DEBUG
        if auth.currentUser == nil, ProcessInfo.processInfo.arguments.contains("-v2DemoPage") { return "K4PQ7M" }
        #endif
        return auth.currentUser?.inviteCode
    }
    private var remaining: Int? {
        if case .remaining(let n) = quota { return n }
        return nil
    }
    private var codeWorks: Bool { remaining != 0 }

    var body: some View {
        V2Screen(title: "Invite", onBack: { dismiss() }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(headline)
                        .font(V2Type.serif(28, relativeTo: .largeTitle))
                        .padding(.top, 16)
                    Text("\(AppInfo.appName) is invite only. The people you bring in will see \u{201C}invited by \(auth.currentUser?.username ?? "you")\u{201D} on their first screen.")
                        .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
                        .foregroundStyle(palette.ink2)
                        .padding(.top, 8)
                    card
                        .frame(maxWidth: .infinity)
                        .padding(.top, 30)
                    if codeWorks, let code {
                        VStack(spacing: 0) {
                            ShareLink(item: AppInfo.personalInviteMessage(code: code)) { row("Send in a message") }
                                .simultaneousGesture(TapGesture().onEnded {
                                    Haptics.tap()
                                    Activation.log(.inviteSent)
                                    Usage.log(.inviteSharedProfile)
                                })
                            Button {
                                UIPasteboard.general.string = code
                                Haptics.success()
                                withAnimation { copied = true }
                            } label: { row(copied ? "Copied" : "Copy the code") }
                                .buttonStyle(.plain)
                            Button { showQR = true } label: { row("Show it as a QR") }
                                .buttonStyle(.plain)
                        }
                        .padding(.top, 30)
                    }
                    Text(InviteCopy.earnBack)
                        .font(V2Type.serif(13, italic: true, relativeTo: .footnote))
                        .foregroundStyle(palette.ink3)
                        .padding(.top, 18)
                    if !sent.isEmpty {
                        Text("Sent")
                            .font(V2Type.serif(13, italic: true, relativeTo: .footnote))
                            .foregroundStyle(palette.ink3)
                            .padding(.top, 30)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(sent) { invite in
                            HStack {
                                Text(invite.handle.map { "@\($0)" } ?? "Someone new")
                                Spacer()
                                Text(status(invite))
                                    .foregroundStyle(palette.ink2)
                            }
                            .font(.system(.subheadline))
                            .padding(.vertical, 10)
                            .overlay(alignment: .bottom) { Rectangle().fill(palette.rule).frame(height: 1) }
                        }
                    }
                }
                .padding(.horizontal, V2Metrics.margin)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
        }
        .sheet(isPresented: $showQR) {
            if let code { V2InviteQR(url: AppInfo.personalInviteURL(code: code)).modifier(V2DeskEnvironment()) }
        }
        .task {
            #if DEBUG
            if auth.currentUser == nil, ProcessInfo.processInfo.arguments.contains("-v2DemoPage") {
                quota = .remaining(3)
                return
            }
            #endif
            quota = await auth.ownInviteQuota()
            sent = await auth.ownInvitesSent()
        }
    }

    /// "Three invites left." in words, as the board writes it; the App Store copy otherwise.
    private var headline: String {
        if let remaining, remaining > 0 {
            let words = V2ScreeningView.number(remaining)
            return "\(words.prefix(1).uppercased() + words.dropFirst()) \(remaining == 1 ? "invite" : "invites") left."
        }
        return InviteCopy.headline(for: quota)
    }

    private var card: some View {
        VStack(spacing: 10) {
            Text(code.map { $0.map(String.init).joined(separator: " ") } ?? "")
                .font(V2Type.data(32))
                .foregroundStyle(V2Color.printInk)
                .opacity(codeWorks ? 1 : 0.35)
                .accessibilityLabel(code.map { "Your code, \($0.map(String.init).joined(separator: " "))" } ?? "")
            Text(codeWorks ? "one friend in, each time it is used" : InviteCopy.subhead(for: quota))
                .font(V2Type.serif(13, italic: true, relativeTo: .footnote))
                .foregroundStyle(V2Color.printInk2)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 20)
        .frame(width: 256, height: 150)
        .background(
            Rectangle().fill(V2Color.print)
                .shadow(color: palette.shadowNear.color, radius: palette.shadowNear.radius, y: palette.shadowNear.y)
                .shadow(color: palette.shadowFar.color, radius: palette.shadowFar.radius, y: palette.shadowFar.y)
        )
    }

    private func row(_ title: String) -> some View {
        HStack {
            Text(title).font(.system(.subheadline))
            Spacer()
            Text("›").foregroundStyle(palette.ink3)
        }
        .foregroundStyle(palette.ink)
        .padding(.vertical, 12)
        .frame(minHeight: 44)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.rule).frame(height: 1) }
        .contentShape(Rectangle())
    }

    private func status(_ invite: AuthService.SentInvite) -> String {
        let kind: InviteCopy.SpentStatus = invite.handle == nil ? .invited : (invite.activated ? .cameBack : .yetToShoot)
        return InviteCopy.spentStatus(for: kind).text
    }
}

/// The invite link as a QR, on a print, for a friend standing next to you.
private struct V2InviteQR: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.v2Palette) private var palette

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            V2PrintCard(width: 280, borderFraction: 20.0 / 280, footFraction: 50.0 / 280) {
                V2Color.print.overlay {
                    if let image = Self.qr(url.absoluteString) {
                        Image(uiImage: image).interpolation(.none).resizable().scaledToFit().padding(10)
                    }
                }
            } foot: {
                Text("point a camera here")
                    .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
                    .foregroundStyle(V2Color.printInk2)
            }
            .accessibilityLabel("QR code for your invite link")
            Spacer()
            Button { dismiss() } label: {
                Text("Done").font(V2Type.control()).frame(minHeight: 44)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .background { V2Desktop(palette: palette) }
        .foregroundStyle(palette.ink)
        .presentationDetents([.large])
    }

    static func qr(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
