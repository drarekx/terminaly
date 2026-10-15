import AppKit
import WebKit

// Renders a local HTML file to PNG at 2x: swift scripts/tools/render-html.swift <in.html> <width> <height> <out.png>
let args = CommandLine.arguments
let (path, w, h, out) = (args[1], Double(args[2])!, Double(args[3])!, args[4])

final class Renderer: NSObject, WKNavigationDelegate {
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: w, height: h))
    func start() {
        web.navigationDelegate = self
        web.loadFileURL(URL(fileURLWithPath: path), allowingReadAccessTo: URL(fileURLWithPath: path).deletingLastPathComponent())
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Wait for web fonts before capturing.
        webView.evaluateJavaScript("document.fonts.ready.then(() => true)") { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let config = WKSnapshotConfiguration()
                config.rect = NSRect(x: 0, y: 0, width: w, height: h)
                config.snapshotWidth = NSNumber(value: w * 2)
                webView.takeSnapshot(with: config) { image, _ in
                    guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                          let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
                    try! png.write(to: URL(fileURLWithPath: out))
                    exit(0)
                }
            }
        }
    }
}

let app = NSApplication.shared
let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: w, height: h), styleMask: [.borderless], backing: .buffered, defer: false)
let renderer = Renderer()
window.contentView = renderer.web
window.orderBack(nil)
renderer.start()
DispatchQueue.main.asyncAfter(deadline: .now() + 20) { exit(2) }
app.run()
