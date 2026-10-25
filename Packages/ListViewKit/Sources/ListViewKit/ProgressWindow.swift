// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DomainKit
import FileOpsKit

// Contract: docs/SDD/06 §6.1 + docs/SDD/02 F-5 — the transfer progress window.
// T-10 stub: textual status + Pause/Resume/Cancel wired to the executor; the
// visual design (transfer queue, per-file rows, close-behaviour) arrives with
// the T-12 UX pass. Closing the window does NOT cancel the operation (F-5:
// «фоновый режим — операция живёт»).

@MainActor
public final class ProgressWindowController: NSWindowController {
    private let executor: any OperationExecutorProtocol
    private let operation: OperationID
    private let statusLine = NSTextField(labelWithString: "")
    private let reportLine = NSTextField(labelWithString: "")
    private let pauseButton = NSButton()
    private var paused = false
    /// F-5 «отчёт по завершении (ok/skip/fail/причины)» — accumulated from
    /// the live event stream (T-12).
    private var report = OperationReport()

    public init(
        id: OperationID,
        events: AsyncStream<TransferEvent>,
        executor: any OperationExecutorProtocol,
        itemCount: Int
    ) {
        self.executor = executor
        self.operation = id

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 110),
            styleMask: [.titled, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "progress.title")
        super.init(window: window)

        statusLine.lineBreakMode = .byTruncatingMiddle
        statusLine.stringValue = String(localized: "progress.starting \(itemCount)")

        reportLine.lineBreakMode = .byWordWrapping
        reportLine.maximumNumberOfLines = 6
        reportLine.isHidden = true

        pauseButton.title = String(localized: "progress.pause")
        pauseButton.bezelStyle = .rounded
        pauseButton.target = self
        pauseButton.action = #selector(pauseClicked)

        let cancelButton = NSButton(title: String(localized: "progress.cancel"), target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded

        let buttons = NSStackView(views: [pauseButton, cancelButton])
        buttons.orientation = .horizontal
        let layout = NSStackView(views: [statusLine, reportLine, buttons])
        layout.orientation = .vertical
        layout.alignment = .leading
        layout.spacing = 10
        layout.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(layout)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 16),
            layout.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -16),
            layout.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 16),
        ])

        consume(events, itemCount: itemCount)
    }

    required init?(coder: NSCoder) {
        fatalError("ProgressWindowController is created programmatically only")
    }

    /// Live event feed → status text + the finish report. The task detaches:
    /// closing the window only stops observing (F-5 background semantics).
    private func consume(_ events: AsyncStream<TransferEvent>, itemCount: Int) {
        Task { [weak self] in
            for await event in events {
                guard let self else { break }
                report.record(event)
                switch event.phase {
                case .started:
                    break
                case .itemProgress(let fraction):
                    let overall = event.totalBytes > 0
                        ? Double(event.completedBytes) / Double(event.totalBytes)
                        : 0
                    statusLine.stringValue = String(
                        localized: "progress.working \(Int(overall * 100)) \(Int(fraction * 100))"
                    )
                case .itemDone:
                    break
                case .itemFailed(let error):
                    statusLine.stringValue = String(localized: "progress.failed \(error.errorDescription ?? "")")
                case .paused:
                    paused = true
                    pauseButton.title = String(localized: "progress.resume")
                case .resumed:
                    paused = false
                    pauseButton.title = String(localized: "progress.pause")
                case .finished:
                    // F-5 «отчёт по завершении (ok/skip/fail/причины)»: the
                    // window stays open until the user closes it — the report
                    // is the record of the operation (T-12).
                    statusLine.stringValue = report.summaryLine
                    let reasons = report.reasonLines
                    if !reasons.isEmpty {
                        reportLine.stringValue = reasons.joined(separator: "\n")
                        reportLine.isHidden = false
                    }
                    pauseButton.isEnabled = false
                }
                _ = itemCount
            }
        }
    }

    @objc private func pauseClicked() {
        Task {
            if paused {
                await executor.resume(operation)
            } else {
                await executor.pause(operation)
            }
        }
    }

    @objc private func cancelClicked() {
        Task { await executor.cancel(operation) }
    }
}
