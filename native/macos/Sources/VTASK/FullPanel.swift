import SwiftUI
import WebKit

struct FullPanel: NSViewRepresentable {
    private static let address = URL(string: "http://127.0.0.1:8765/")!

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.load(URLRequest(url: Self.address))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url, url.scheme == "http",
                  url.host == FullPanel.address.host, url.port == FullPanel.address.port else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(action.shouldPerformDownload ? .download : .allow)
        }

        func webView(_ view: WKWebView, decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            let disposition = (response.response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Content-Disposition") ?? ""
            decisionHandler(disposition.lowercased().hasPrefix("attachment") || !response.canShowMIMEType ? .download : .allow)
        }

        func webView(_ view: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            download.delegate = self
        }

        func webView(_ view: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
        }

        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                      suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = suggestedFilename
            completionHandler(panel.runModal() == .OK ? panel.url : nil)
        }

        func webView(_ view: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: "Подтвердить")
            alert.addButton(withTitle: "Отмена")
            if let window = view.window {
                alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
            } else {
                completionHandler(false)
            }
        }

        func webView(_ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            let alert = NSAlert()
            alert.messageText = "Панель VTASK недоступна"
            alert.informativeText = "Проверьте, запущено ли локальное ядро VTASK."
            alert.addButton(withTitle: "Повторить")
            alert.addButton(withTitle: "Закрыть")
            if alert.runModal() == .alertFirstButtonReturn {
                view.load(URLRequest(url: FullPanel.address))
            }
        }
    }
}
