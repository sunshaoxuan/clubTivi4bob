import AppKit
import Foundation
import Darwin

final class UpdatePanel: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 16/255, green: 25/255, blue: 42/255, alpha: 1).setFill()
        dirtyRect.fill()
    }
}

// Separate native status process. Closing this window never cancels the worker.
final class UpdateProgress: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let root: URL
    let app: URL
    let playerPID: Int32
    let workerPID: Int32
    let version: String
    let runID: String
    let snapshotPath: String?
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    let phase = NSTextField(labelWithString: "正在读取更新进度")
    let detail = NSTextField(wrappingLabelWithString: "请稍候，更新会在此窗口显示进度。")
    let note = NSTextField(labelWithString: "关闭这个状态窗口不会中止更新。")
    let bar = NSProgressIndicator()
    let spinner = NSProgressIndicator()
    let launch = NSButton(title: "立即启动 BobTV", target: nil, action: nil)
    var timer: Timer?
    var shown = false
    var finishedAt: Date?
    var startedAt = Date()
    var lastPhase = ""

    func log(_ message: String) {
        let file = root.appendingPathComponent("progress-ui.log")
        if !FileManager.default.fileExists(atPath: file.path) { _ = FileManager.default.createFile(atPath: file.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(Data((ISO8601DateFormatter().string(from: Date()) + " " + message + "\n").utf8))
    }

    init(arguments: [String]) {
        root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        app = URL(fileURLWithPath: arguments[2], isDirectory: true)
        playerPID = Int32(arguments[3]) ?? 0
        workerPID = Int32(arguments[4]) ?? 0
        version = arguments[5]
        runID = arguments[6]
        snapshotPath = arguments.count == 9 ? arguments[8] : nil
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        window.title = "BobTV 更新"
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.delegate = self
        let panel = UpdatePanel()
        panel.appearance = NSAppearance(named: .darkAqua)
        window.contentView = panel
        let title = NSTextField(labelWithString: "BobTV \(version)")
        title.font = .systemFont(ofSize: 25, weight: .bold)
        title.textColor = .white
        phase.font = .systemFont(ofSize: 17, weight: .semibold)
        phase.textColor = NSColor(calibratedWhite: 0.94, alpha: 1)
        detail.font = .systemFont(ofSize: 13); detail.maximumNumberOfLines = 4
        detail.textColor = NSColor(calibratedWhite: 0.80, alpha: 1)
        note.font = .systemFont(ofSize: 11); note.textColor = NSColor(calibratedWhite: 0.64, alpha: 1)
        bar.style = .bar; bar.isIndeterminate = true; bar.minValue = 0; bar.maxValue = 100
        spinner.style = .spinning; spinner.controlSize = .small
        spinner.startAnimation(nil)
        let statusRow = NSStackView(views: [spinner, phase]); statusRow.spacing = 10
        launch.target = self; launch.action = #selector(openPlayer); launch.bezelStyle = .rounded
        launch.isEnabled = false
        let stack = NSStackView(views: [title, statusRow, bar, detail, note, launch])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -26),
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 24),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        if snapshotPath == nil { timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() } }
        refresh()
        if let path = snapshotPath, let content = window.contentView {
            content.layoutSubtreeIfNeeded()
            guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { exit(3) }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(3) }
            do { try png.write(to: URL(fileURLWithPath: path)) } catch { exit(3) }
            exit(0)
        }
    }

    func alive(_ pid: Int32) -> Bool { pid > 0 && (kill(pid, 0) == 0 || errno == EPERM) }

    func refresh() {
        guard snapshotPath != nil || !alive(playerPID) else { return }
        if !shown {
            shown = true; startedAt = Date()
            if snapshotPath == nil {
                window.center(); window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                log("window_shown run=\(runID)")
            }
        }
        let file = root.appendingPathComponent("status-\(runID).json")
        guard let data = try? Data(contentsOf: file),
              let state = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              state["runId"] as? String == runID, state["version"] as? String == version else {
            if Date().timeIntervalSince(startedAt) > 30 || !alive(workerPID) {
                failure("更新助手未返回状态", "下载或安装尚未确认。请查看 worker.log，重新启动 BobTV 后重试。")
            }
            return
        }
        let status = state["phase"] as? String ?? "starting"
        if status != lastPhase { lastPhase = status; if snapshotPath == nil { log("phase=\(status) run=\(runID)") } }
        let percent = min(100, max(0, (state["percent"] as? NSNumber)?.doubleValue ?? 0))
        let titles = ["starting": "正在准备下载", "downloading": "正在下载更新 \(Int(percent))%",
                      "verifying": "正在校验安装包", "ready": "下载完成，等待播放器退出",
                      "backingUp": "正在备份旧版", "installing": "正在安装更新",
                      "installed": "更新已完成", "failed": "更新未完成"]
        phase.stringValue = titles[status] ?? "正在处理更新"
        detail.stringValue = state["message"] as? String ?? "更新正在进行中。"
        if status == "downloading", let received = state["receivedBytes"] as? NSNumber,
           let total = state["totalBytes"] as? NSNumber, total.int64Value > 0 {
            detail.stringValue += String(format: "  %.1f / %.1f MB", received.doubleValue / 1048576, total.doubleValue / 1048576)
        }
        bar.isIndeterminate = !["downloading", "ready", "installed", "failed"].contains(status)
        if bar.isIndeterminate { bar.startAnimation(nil) } else { bar.stopAnimation(nil); bar.doubleValue = percent }
        if status == "installed" {
            spinner.stopAnimation(nil); spinner.isHidden = true; launch.isEnabled = true
            if finishedAt == nil { finishedAt = Date() }
            let remaining = max(0, 20 - Int(Date().timeIntervalSince(finishedAt!)))
            note.stringValue = "旧版备份已保留。此窗口将在 \(remaining) 秒后关闭。"
            if remaining == 0 { NSApp.terminate(nil) }
        } else if status == "failed" {
            failure(phase.stringValue, detail.stringValue)
        } else if snapshotPath == nil && !alive((state["workerPid"] as? NSNumber)?.int32Value ?? workerPID) {
            failure("更新助手意外退出", "更新尚未完成。请查看 worker.log，重新启动 BobTV 后重试。")
        }
    }

    func failure(_ title: String, _ message: String) {
        phase.stringValue = title; detail.stringValue = message
        spinner.stopAnimation(nil); spinner.isHidden = true
        bar.stopAnimation(nil); bar.isIndeterminate = false
        launch.isEnabled = true; note.stringValue = "可重新启动 BobTV 重试，旧版备份不会被删除。"
    }
    @objc func openPlayer() { NSWorkspace.shared.open(app); NSApp.terminate(nil) }
    func windowWillClose(_ notification: Notification) { timer?.invalidate(); NSApp.terminate(nil) }
}

let arguments = CommandLine.arguments
let snapshot = arguments.count == 9 && arguments[7] == "--snapshot" &&
    ProcessInfo.processInfo.environment["CI"] == "true" &&
    arguments[8].hasPrefix(FileManager.default.temporaryDirectory.path + "/")
guard arguments.count == 7 || snapshot,
      CommandLine.arguments[6].range(of: "^[A-Za-z0-9-]{1,100}$", options: .regularExpression) != nil else { exit(2) }
let delegate = UpdateProgress(arguments: CommandLine.arguments)
let application = NSApplication.shared
application.delegate = delegate
application.run()
