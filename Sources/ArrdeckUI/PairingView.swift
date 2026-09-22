import ArrdeckKit
import SwiftUI
import WebKit

/// The auth step, in a web view against the user's own origin — the one place
/// WebAuthn works for an app that cannot know its backends at compile time
/// (associated domains are a build-time entitlement). Zero backend changes:
/// the PWA's login screen runs as-is, and this view only watches for the
/// session cookie it sets.
public struct PairingView: View {
    let profile: ServerProfile
    let onPaired: () -> Void

    public init(profile: ServerProfile, onPaired: @escaping () -> Void) {
        self.profile = profile
        self.onPaired = onPaired
    }

    public var body: some View {
        PairingWebView(
            url: profile.baseURL,
            watcher: PairingWatcher(for: profile.baseURL)
        ) { cookie in
            // Into the app's own jar: the web view's store and URLSession's do
            // not share, and every API call after this moment must carry it.
            HTTPCookieStorage.shared.setCookie(cookie)
            onPaired()
        }
    }
}

struct PairingWebView {
    let url: URL
    let watcher: PairingWatcher
    let onCookie: @MainActor (HTTPCookie) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(watcher: watcher, onCookie: onCookie)
    }

    @MainActor
    func makeWebView(coordinator: Coordinator) -> WKWebView {
        let config = WKWebViewConfiguration()
        // The persistent store on purpose: a passkey ceremony can bounce
        // through redirects, and the cookie must survive them. It also means a
        // re-pair of an already-signed-in profile completes instantly.
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        config.websiteDataStore.httpCookieStore.add(coordinator)
        // The observer only fires on *changes* — a cookie already sitting in
        // the store from an earlier pairing needs this initial sweep.
        coordinator.sweep(config.websiteDataStore.httpCookieStore)
        webView.load(URLRequest(url: url))
        return webView
    }

    final class Coordinator: NSObject, WKHTTPCookieStoreObserver {
        let watcher: PairingWatcher
        let onCookie: @MainActor (HTTPCookie) -> Void

        init(watcher: PairingWatcher, onCookie: @escaping @MainActor (HTTPCookie) -> Void) {
            self.watcher = watcher
            self.onCookie = onCookie
        }

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            sweep(cookieStore)
        }

        func sweep(_ store: WKHTTPCookieStore) {
            store.getAllCookies { [watcher, onCookie] cookies in
                guard let match = watcher.observe(cookies) else { return }
                Task { @MainActor in onCookie(match) }
            }
        }
    }
}

#if canImport(UIKit)
extension PairingWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        makeWebView(coordinator: context.coordinator)
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
#else
extension PairingWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        makeWebView(coordinator: context.coordinator)
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}
}
#endif
