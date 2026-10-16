import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var playerChannel: FlutterMethodChannel?
  private var normalFrame: NSRect?
  private var storageChannel: FlutterMethodChannel?
  private var storageURLs: [URL] = []

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let channel = FlutterMethodChannel(
      name: "dev.peerstream/storage",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    storageChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "chooseFolder":
        let panel = NSOpenPanel()
        panel.title = "Choose PeerStream storage folder"
        panel.message = "Use an empty folder for saved video, artwork and app data."
        panel.prompt = "Use this folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: self) { response in
          guard response == .OK, let url = panel.url else {
            result(nil)
            return
          }
          do {
            let bookmark = try url.bookmarkData(options: .withSecurityScope,
              includingResourceValuesForKeys: nil, relativeTo: nil)
            if url.startAccessingSecurityScopedResource() { self.storageURLs.append(url) }
            result(["path": url.path, "bookmark": bookmark.base64EncodedString()])
          } catch {
            result(FlutterError(code: "folder_access", message: error.localizedDescription, details: nil))
          }
        }
      case "restoreAccess":
        guard let args = call.arguments as? [String: Any],
              let encoded = args["bookmark"] as? String,
              let data = Data(base64Encoded: encoded) else {
          result(FlutterError(code: "folder_access", message: "Select the folder again to grant access.", details: nil))
          return
        }
        do {
          var stale = false
          let url = try URL(resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI], relativeTo: nil,
            bookmarkDataIsStale: &stale)
          guard url.startAccessingSecurityScopedResource() else {
            result(FlutterError(code: "folder_access", message: "Reconnect the storage drive or select the folder again.", details: nil))
            return
          }
          self.storageURLs.append(url)
          let refreshed = stale
            ? try url.bookmarkData(options: .withSecurityScope,
                includingResourceValuesForKeys: nil, relativeTo: nil)
            : data
          result(["path": url.path, "bookmark": refreshed.base64EncodedString()])
        } catch {
          result(FlutterError(code: "folder_access", message: error.localizedDescription, details: nil))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let player = FlutterMethodChannel(name: "dev.peerstream/window", binaryMessenger: flutterViewController.engine.binaryMessenger)
    playerChannel = player
    player.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "miniPlayer":
        guard !self.styleMask.contains(.fullScreen) else {
          result(FlutterError(code: "fullscreen", message: "Leave fullscreen before opening the mini-player.", details: nil)); return
        }
        let enabled = (call.arguments as? Bool) ?? false
        if enabled {
          if self.normalFrame == nil { self.normalFrame = self.frame }
          self.level = .floating
          self.setContentSize(NSSize(width: 480, height: 300))
        } else {
          self.level = .normal
          if let frame = self.normalFrame { self.setFrame(frame, display: true) }
          self.normalFrame = nil
        }
        result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }

  deinit {
    for url in storageURLs { url.stopAccessingSecurityScopedResource() }
  }
}
