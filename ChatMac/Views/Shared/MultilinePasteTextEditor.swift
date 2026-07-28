import AppKit
import SwiftUI

struct MultilinePasteTextEditor: NSViewRepresentable {
    @Binding var text: String
    let onMultilinePaste: (String) -> Void
    let onSubmit: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = MultilinePasteNSTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = .systemFont(ofSize: 14.5)
        textView.textColor = NSColor(AeroTheme.text)
        textView.insertionPointColor = NSColor(AeroTheme.deepSky)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainerInset = NSSize(width: 2, height: 5)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        applyTextStyle(to: textView)
        configure(textView)
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MultilinePasteNSTextView else { return }
        configure(textView)
        guard textView.string != text else { return }

        context.coordinator.isSynchronizing = true
        let insertionPoint = min(textView.selectedRange().location, text.utf16.count)
        textView.string = text
        textView.setSelectedRange(NSRange(location: insertionPoint, length: 0))
        applyTextStyle(to: textView)
        context.coordinator.isSynchronizing = false
    }

    private func configure(_ textView: MultilinePasteNSTextView) {
        textView.onMultilinePaste = onMultilinePaste
        textView.onSubmit = onSubmit
    }

    private func applyTextStyle(to textView: NSTextView) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 5
        textView.defaultParagraphStyle = paragraphStyle
        textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: 14.5),
            .foregroundColor: NSColor(AeroTheme.text),
            .paragraphStyle: paragraphStyle
        ]
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        var isSynchronizing = false

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard !isSynchronizing,
                  let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }
    }
}

private final class MultilinePasteNSTextView: NSTextView {
    var onMultilinePaste: ((String) -> Void)?
    var onSubmit: (() -> Bool)?

    override func paste(_ sender: Any?) {
        guard let pastedText = NSPasteboard.general.string(forType: .string),
              pastedText.rangeOfCharacter(from: .newlines) != nil else {
            super.paste(sender)
            return
        }
        onMultilinePaste?(pastedText)
    }

    override func keyDown(with event: NSEvent) {
        let isReturnKey = event.keyCode == 36 || event.keyCode == 76
        let hasShiftModifier = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .contains(.shift)
        if isReturnKey,
           !hasShiftModifier,
           !hasMarkedText(),
           onSubmit?() == true {
            return
        }
        super.keyDown(with: event)
    }
}
