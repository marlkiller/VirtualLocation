import SwiftUI
import AppKit

class LogTextViewImpl: NSTextView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}

struct LogTextView: NSViewRepresentable {
    let logs: [LogEntry]

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor

        let tv = LogTextViewImpl()
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.textColor = .labelColor
        tv.drawsBackground = false
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        scroll.documentView = tv
        context.coordinator.textView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        let attr = NSMutableAttributedString()

        for entry in logs {
            let color: NSColor = {
                switch entry.level {
                case .cmd:  return .systemBlue
                case .out:  return .labelColor
                case .err:  return .systemRed
                case .info: return .secondaryLabelColor
                }
            }()
            let line = NSAttributedString(string: entry.formatted + "\n", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: color,
            ])
            attr.append(line)
        }

        let shouldScroll = context.coordinator.shouldAutoScroll
        tv.textStorage?.setAttributedString(attr)

        if shouldScroll, attr.length > 0 {
            tv.scrollRangeToVisible(NSRange(location: attr.length - 1, length: 0))
        }
    }

    class Coordinator {
        weak var textView: NSTextView?
        var shouldAutoScroll = true

        init() {
            NotificationCenter.default.addObserver(forName: NSScrollView.didLiveScrollNotification, object: nil, queue: .main) { [weak self] _ in
                guard let tv = self?.textView,
                      let scroll = tv.enclosingScrollView else { return }
                let maxY = tv.bounds.height - scroll.documentVisibleRect.height
                self?.shouldAutoScroll = abs(scroll.documentVisibleRect.minY - maxY) < 20
            }
        }
    }
}
