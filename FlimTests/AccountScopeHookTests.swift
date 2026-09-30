import SwiftUI
import UIKit
import XCTest
@testable import Flim

/// `AccountScopeHook`, hosted for real: the per-account setup must run for an account already
/// present at first render. Build 422 shipped without that (a launch from the cached profile set
/// the account before the first draw, and a plain `onChange` never saw it), so the seen store
/// stayed signed out and every feed card read "N new". A pure-logic test could not have caught
/// it; only a view actually rendering can.
@MainActor
final class AccountScopeHookTests: XCTestCase {

    private var savedActivated: UUID?
    private var window: UIWindow?

    override func setUp() {
        super.setUp()
        // Process-wide state: start clean, and give the host app its value back afterwards.
        savedActivated = AccountScopeHook.activatedAccountId
        AccountScopeHook.activatedAccountId = nil
    }

    override func tearDown() {
        window?.isHidden = true
        window = nil
        AccountScopeHook.activatedAccountId = savedActivated
        super.tearDown()
    }

    private struct Call: Equatable {
        let previous: UUID?
        let new: UUID?
    }

    /// Mounts a hook for `accountId` in a real window, records what it fires, and lets it render.
    private func mount(_ accountId: UUID?, into calls: @escaping (Call) -> Void) -> UIHostingController<AnyView> {
        let host = UIHostingController(rootView: hosted(accountId, calls))
        // On the host app's scene: in a scene-based app a window without one is never shown,
        // and a view that never renders never fires anything.
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        self.window?.isHidden = true
        window.rootViewController = host
        window.makeKeyAndVisible()
        self.window = window
        spin()
        return host
    }

    private func hosted(_ accountId: UUID?, _ calls: @escaping (Call) -> Void) -> AnyView {
        AnyView(Color.clear.modifier(AccountScopeHook(accountId: accountId) { previous, new in
            calls(Call(previous: previous, new: new))
        }))
    }

    private func spin() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }

    func testAnAccountPresentAtFirstRenderFiresOnce() {
        let account = UUID()
        var calls: [Call] = []
        _ = mount(account) { calls.append($0) }

        XCTAssertEqual(calls, [Call(previous: nil, new: account)],
                       "the account already there when the view first draws must be activated")
    }

    func testAnAccountArrivingAfterFirstRenderFiresOnce() {
        let account = UUID()
        var calls: [Call] = []
        let host = mount(nil) { calls.append($0) }
        XCTAssertEqual(calls, [], "no account yet, nothing to activate")

        host.rootView = hosted(account) { calls.append($0) }
        spin()

        XCTAssertEqual(calls, [Call(previous: nil, new: account)])
    }

    func testTheSameAccountNeverFiresTwiceEvenInARebuiltScene() {
        let account = UUID()
        var calls: [Call] = []
        let host = mount(account) { calls.append($0) }

        // Re-rendered with the same account.
        host.rootView = hosted(account) { calls.append($0) }
        spin()
        // And mounted afresh, as a scene rebuilt while the process lives would mount it: view
        // state starts empty, the activated account does not.
        _ = mount(account) { calls.append($0) }

        XCTAssertEqual(calls, [Call(previous: nil, new: account)],
                       "the resets run once per account, not once per scene")
    }
}
