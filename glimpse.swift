import AVFoundation
import Cocoa
import Foundation
import WebKit

func writeToStdout(_ dict: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: dict),
          let line = String(data: data, encoding: .utf8) else { return }
    FileHandle.standardOutput.write((line + "\n").data(using: .utf8)!)
    fflush(stdout)
}

func log(_ message: String) {
    fputs("[glimpse] \(message)\n", stderr)
}

struct Config {
    var width: Int? = nil
    var height: Int? = nil
    var title: String = "Glimpse"
    var autoClose: Bool = false
    var resizable: Bool = false
}

func parseArgs() -> Config {
    var config = Config()
    let args = CommandLine.arguments
    var i = 1

    while i < args.count {
        switch args[i] {
        case "--width":
            i += 1
            if i < args.count, let value = Int(args[i]) { config.width = value }
        case "--height":
            i += 1
            if i < args.count, let value = Int(args[i]) { config.height = value }
        case "--title":
            i += 1
            if i < args.count { config.title = args[i] }
        case "--auto-close":
            config.autoClose = true
        case "--resizable":
            config.resizable = true
        default:
            break
        }
        i += 1
    }

    return config
}

final class GlimpseWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate, NSWindowDelegate {
    private let config: Config
    private var window: NSWindow!
    private var webView: WKWebView!
    private var isExiting = false
    private let localBaseURL = URL(string: "https://localhost/")!

    nonisolated init(config: Config) {
        self.config = config
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupWindow()
        setupWebView()
        startStdinReader()
    }

    private func setupWindow() {
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let adaptiveWidth = Int(visibleFrame.width * 0.8)
        let adaptiveHeight = Int(visibleFrame.height * 0.8)
        let windowWidth = max(640, config.width ?? adaptiveWidth)
        let windowHeight = max(480, config.height ?? adaptiveHeight)
        let rect = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)

        var styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if config.resizable {
            styleMask.insert(.resizable)
        }

        window = GlimpseWindow(
            contentRect: rect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = config.title
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func setupWebView() {
        let controller = WKUserContentController()
        let bridgeJS = """
        window.glimpse = {
            send: function(data) {
                window.webkit.messageHandlers.glimpse.postMessage(JSON.stringify(data));
            },
            close: function() {
                window.webkit.messageHandlers.glimpse.postMessage(JSON.stringify({__glimpse_close: true}));
            }
        };
        """
        controller.addUserScript(WKUserScript(source: bridgeJS, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.add(self, name: "glimpse")

        let webConfig = WKWebViewConfiguration()
        webConfig.userContentController = controller
        webConfig.defaultWebpagePreferences.allowsContentJavaScript = true

        webView = WKWebView(frame: window.contentView!.bounds, configuration: webConfig)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.uiDelegate = self
        window.contentView?.addSubview(webView)

        webView.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: localBaseURL)
    }

    private func loadHTML(_ html: String) {
        webView.loadHTMLString(html, baseURL: localBaseURL)
    }

    private func startStdinReader() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while let line = readLine() {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                guard let data = trimmed.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type = json["type"] as? String else {
                    log("Skipping invalid JSON: \(trimmed)")
                    continue
                }

                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.handleCommand(type: type, payload: json)
                    }
                }
            }

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.closeAndExit()
                }
            }
        }
    }

    private func handleCommand(type: String, payload: [String: Any]) {
        switch type {
        case "html":
            guard let base64 = payload["html"] as? String,
                  let data = Data(base64Encoded: base64),
                  let html = String(data: data, encoding: .utf8) else {
                log("html command missing valid base64 payload")
                return
            }
            loadHTML(html)
        case "close":
            closeAndExit()
        default:
            log("Unknown command type: \(type)")
        }
    }

    private func requestAuthorization(for mediaType: AVMediaType, completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: mediaType) { granted in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    @available(macOS 12.0, *)
    private func requestCaptureAccess(for captureType: WKMediaCaptureType, completion: @escaping (Bool) -> Void) {
        switch captureType {
        case .camera:
            requestAuthorization(for: .video, completion: completion)
        case .microphone:
            requestAuthorization(for: .audio, completion: completion)
        case .cameraAndMicrophone:
            requestAuthorization(for: .video) { [weak self] granted in
                guard granted, let self else {
                    completion(false)
                    return
                }
                self.requestAuthorization(for: .audio, completion: completion)
            }
        @unknown default:
            completion(false)
        }
    }

    @available(macOS 12.0, *)
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        requestCaptureAccess(for: type) { granted in
            decisionHandler(granted ? .grant : .deny)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            writeToStdout(["type": "ready"])
        }
    }

    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let body = message.body as? String,
                  let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                log("Received invalid message from webview")
                return
            }

            if json["__glimpse_close"] as? Bool == true {
                closeAndExit()
                return
            }

            writeToStdout(["type": "message", "data": json])
            if config.autoClose {
                closeAndExit()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        closeAndExit()
    }

    private func closeAndExit() {
        guard !isExiting else { return }
        isExiting = true
        writeToStdout(["type": "closed"])
        exit(0)
    }
}

let config = parseArgs()
let app = NSApplication.shared
let delegate = AppDelegate(config: config)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
