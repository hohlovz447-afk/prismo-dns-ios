import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

public struct LogView: View {
    let logs: [String]
    let onClear: () -> Void

    public init(logs: [String], onClear: @escaping () -> Void) {
        self.logs = logs
        self.onClear = onClear
    }

    private var joined: String { logs.joined(separator: "\n") }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(AppLocalization.string("Logs"), systemImage: "list.bullet.rectangle")
                    #if os(iOS)
                    .font(.subheadline.weight(.semibold))
                    #else
                    .font(.headline)
                    #endif
                Spacer()
                Button(action: copyLogs) {
                    Label(AppLocalization.string("Copy"), systemImage: "doc.on.doc")
                }
                .disabled(logs.isEmpty)
                Button(action: onClear) {
                    Label(AppLocalization.string("Clear"), systemImage: "trash")
                }
                .disabled(logs.isEmpty)
            }
            .padding([.horizontal, .top])

            #if os(iOS)
            SelectableLogTextView(text: joined)
                .background(Color(.systemBackground))
            #else
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading) {
                        if logs.isEmpty {
                            Text(AppLocalization.string("No log lines yet."))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text(joined)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding()
                }
                .onChange(of: logs.count) { _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(iOS)
        .font(.subheadline)
        #endif
    }

    private func copyLogs() {
        let text = joined
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

#if os(iOS)
// UITextView gives proper iOS text selection: long-press magnifier,
// grab handles, word-level snap, copy/share menu, cross-line selection.
private struct SelectableLogTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.dataDetectorTypes = []
        textView.backgroundColor = .systemBackground
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        textView.font = UIFont.monospacedSystemFont(ofSize: UIFont.smallSystemFontSize, weight: .regular)
        textView.textColor = .secondaryLabel
        textView.text = text.isEmpty ? AppLocalization.string("No log lines yet.") : text
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        let displayedText = text.isEmpty ? AppLocalization.string("No log lines yet.") : text
        let userIsSelecting = textView.selectedRange.length > 0

        if textView.text != displayedText {
            let wasNearBottom = isNearBottom(textView)
            textView.text = displayedText
            if wasNearBottom && !userIsSelecting {
                scrollToBottom(textView)
            }
        }
    }

    private func isNearBottom(_ textView: UITextView, threshold: CGFloat = 40) -> Bool {
        let offsetBottom = textView.contentOffset.y + textView.bounds.height
        let contentHeight = textView.contentSize.height
        return offsetBottom >= contentHeight - threshold
    }

    private func scrollToBottom(_ textView: UITextView) {
        let bottomOffset = max(0, textView.contentSize.height - textView.bounds.height + textView.contentInset.bottom)
        textView.setContentOffset(CGPoint(x: 0, y: bottomOffset), animated: false)
    }
}
#endif
