import Cocoa
import FlutterMacOS
import UniformTypeIdentifiers

class MainFlutterWindow: NSWindow {
  private var videoChannel: FlutterMethodChannel?
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

    let video = FlutterMethodChannel(name: "dev.peerstream/video", binaryMessenger: flutterViewController.engine.binaryMessenger)
    videoChannel = video
    video.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(FlutterError(code: "window_closed", message: "The window closed.", details: nil)); return }
      switch call.method {
      case "players":
        let installed = [("org.videolan.vlc", "VLC"), ("com.colliderli.iina", "IINA"), ("io.mpv", "mpv")].compactMap { (id, name) -> [String: String]? in
          guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil else { return nil }
          return ["id": id, "name": name]
        }
        result(installed)
      case "choosePlayer":
        let panel = NSOpenPanel()
        panel.title = "Choose a video player"
        panel.message = "Choose VLC, IINA, or another player that supports this video."
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: self) { response in
          guard response == .OK, let url = panel.url else { result(nil); return }
          guard Bundle(url: url)?.bundleIdentifier != Bundle.main.bundleIdentifier else {
            result(FlutterError(code: "invalid_player", message: "Choose a different video player.", details: nil)); return
          }
          result(["id": url.path, "name": url.deletingPathExtension().lastPathComponent])
        }
      case "open":
        guard let args = call.arguments as? [String: String],
          let text = args["uri"], let url = URL(string: text),
          ["http", "https", "file"].contains(url.scheme?.lowercased() ?? ""),
          let application = args["application"] else {
          result(FlutterError(code: "invalid_video", message: "A playable video URL is required.", details: nil)); return
        }
        let appURL = application.hasPrefix("/") ? URL(fileURLWithPath: application) : NSWorkspace.shared.urlForApplication(withBundleIdentifier: application)
        guard let appURL = appURL, appURL.pathExtension.lowercased() == "app",
          FileManager.default.fileExists(atPath: appURL.path),
          Bundle(url: appURL)?.bundleIdentifier != Bundle.main.bundleIdentifier else {
          result(FlutterError(code: "player_missing", message: "The selected player is unavailable. Choose another player.", details: nil)); return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config) { _, error in
          DispatchQueue.main.async {
            if error != nil { result(FlutterError(code: "player_open", message: "The video could not be sent to that player. Try another installed player.", details: nil)) }
            else { result(nil) }
          }
        }
      case "export":
        guard let args = call.arguments as? [String: String], let path = args["path"], let name = args["name"],
          FileManager.default.fileExists(atPath: path) else {
          result(FlutterError(code: "file_missing", message: "The saved video is unavailable. Reconnect its drive.", details: nil)); return
        }
        let panel = NSSavePanel()
        panel.title = "Save video file"
        panel.nameFieldStringValue = (name as NSString).lastPathComponent
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: self) { response in
          guard response == .OK, let destination = panel.url else { result(nil); return }
          let source = URL(fileURLWithPath: path)
          if source.standardizedFileURL == destination.standardizedFileURL { result(destination.path); return }
          let accessing = destination.startAccessingSecurityScopedResource()
          DispatchQueue.global(qos: .utility).async {
            let temp = destination.deletingLastPathComponent().appendingPathComponent(".peerstream-export-" + UUID().uuidString)
            defer {
              try? FileManager.default.removeItem(at: temp)
              if accessing { destination.stopAccessingSecurityScopedResource() }
            }
            do {
              try FileManager.default.copyItem(at: source, to: temp)
              if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
              } else { try FileManager.default.moveItem(at: temp, to: destination) }
              DispatchQueue.main.async { result(destination.path) }
            } catch {
              DispatchQueue.main.async { result(FlutterError(code: "export_failed", message: "Could not save the copy. Check free space and folder access.", details: nil)) }
            }
          }
        }
      default: result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }

  deinit {
    for url in storageURLs { url.stopAccessingSecurityScopedResource() }
  }
}
