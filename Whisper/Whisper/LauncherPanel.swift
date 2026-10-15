import AppKit

@MainActor
final class LauncherPanel {
    private let window: NSPanel
    private let onRecord: () -> Void
    private var eventMonitor: Any?
    private var container: DropView!
    private var glassButton: NSVisualEffectView!
    private var micIcon: NSImageView!
    private var label: NSTextField!
    private var clickButton: NSButton!
    private var statsCard: NSVisualEffectView!
    private var statsNumberLabel: NSTextField!
    private var statsDescLabel: NSTextField!
    private var statsClickButton: NSButton!
    private var transcriptionItems: [NSView] = []
    private var scrollView: NSScrollView?
    private var dismissButton: NSButton?
    private var isExpanded = false
    private var recentTexts: [String] = []
    private let buttonHeight: CGFloat = 48
    private let cardHeight: CGFloat = 80
    private let itemHeight: CGFloat = 54
    private let expandedCardWidth: CGFloat = 320
    private let maxExpandedHeight: CGFloat = 400
    private let dividerGap: CGFloat = 12
    private let padding: CGFloat = 16
    private let iconSize: CGFloat = 20
    private let spacing: CGFloat = 10
    private var animationTimer: Timer?
    private var rotationAngle: CGFloat = 0
    private var transcribeFrame: Int = 0
    private var transcriptionCount: Int = 0
    private let circleSize: CGFloat = 36
    private let circleGap: CGFloat = 8
    private var queueCircles: [NSVisualEffectView] = []
    private var queueIcons: [NSImageView] = []
    private var queueCount: Int = 0
    private var liveTextBubble: NSVisualEffectView?
    private var liveTextLabel: NSTextField?
    private var progressBar: NSProgressIndicator?

    init(onRecord: @escaping () -> Void) {
        self.onRecord = onRecord

        label = NSTextField(labelWithString: "hold right ⌥ to dictate")
        label.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.sizeToFit()

        let buttonWidth = padding + iconSize + spacing + label.frame.width + padding
        let cornerRadius = buttonHeight / 2
        let totalHeight = buttonHeight + dividerGap + cardHeight

        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: buttonWidth, height: totalHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.hidesOnDeactivate = false

        container = DropView(frame: NSRect(x: 0, y: 0, width: buttonWidth, height: totalHeight))

        glassButton = NSVisualEffectView(frame: NSRect(x: 0, y: cardHeight + dividerGap, width: buttonWidth, height: buttonHeight))
        glassButton.material = .hudWindow
        glassButton.state = .active
        glassButton.blendingMode = .behindWindow
        glassButton.wantsLayer = true
        glassButton.layer?.cornerRadius = cornerRadius
        glassButton.layer?.masksToBounds = true
        glassButton.alphaValue = 0.6

        micIcon = NSImageView(frame: NSRect(x: padding, y: (buttonHeight - iconSize) / 2, width: iconSize, height: iconSize))
        micIcon.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)
        micIcon.contentTintColor = .labelColor
        micIcon.imageScaling = .scaleProportionallyUpOrDown

        label.frame.origin = NSPoint(x: padding + iconSize + spacing, y: (buttonHeight - label.frame.height) / 2)

        clickButton = NSButton(frame: NSRect(x: 0, y: 0, width: buttonWidth, height: buttonHeight))
        clickButton.title = ""
        clickButton.bezelStyle = .regularSquare
        clickButton.isBordered = false
        clickButton.isTransparent = true
        clickButton.target = self
        clickButton.action = #selector(recordClicked)

        glassButton.addSubview(micIcon)
        glassButton.addSubview(label)
        glassButton.addSubview(clickButton)

        statsNumberLabel = NSTextField(labelWithString: "0")
        statsNumberLabel.font = NSFont.systemFont(ofSize: 32, weight: .semibold)
        statsNumberLabel.textColor = .labelColor
        statsNumberLabel.backgroundColor = .clear
        statsNumberLabel.isBezeled = false
        statsNumberLabel.isEditable = false
        statsNumberLabel.alignment = .center

        statsDescLabel = NSTextField(labelWithString: "transcriptions")
        statsDescLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        statsDescLabel.textColor = .secondaryLabelColor
        statsDescLabel.backgroundColor = .clear
        statsDescLabel.isBezeled = false
        statsDescLabel.isEditable = false
        statsDescLabel.alignment = .center

        statsCard = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: buttonWidth, height: cardHeight))
        statsCard.material = .hudWindow
        statsCard.state = .active
        statsCard.blendingMode = .behindWindow
        statsCard.wantsLayer = true
        statsCard.layer?.cornerRadius = 16
        statsCard.layer?.masksToBounds = true
        statsCard.alphaValue = 0.6
        statsCard.isHidden = true

        statsNumberLabel.frame = NSRect(x: 0, y: cardHeight - 50, width: buttonWidth, height: 40)
        statsDescLabel.frame = NSRect(x: 0, y: 14, width: buttonWidth, height: 16)

        statsClickButton = NSButton(frame: NSRect(x: 0, y: 0, width: buttonWidth, height: cardHeight))
        statsClickButton.title = ""
        statsClickButton.bezelStyle = .regularSquare
        statsClickButton.isBordered = false
        statsClickButton.isTransparent = true
        statsClickButton.target = self
        statsClickButton.action = #selector(statsCardClicked)

        statsCard.addSubview(statsNumberLabel)
        statsCard.addSubview(statsDescLabel)
        statsCard.addSubview(statsClickButton)

        container.addSubview(glassButton)
        container.addSubview(statsCard)
        window.contentView = container
    }

    func updateStats(transcriptionCount: Int, recentTexts: [String] = []) {
        self.transcriptionCount = transcriptionCount
        self.recentTexts = recentTexts
        statsNumberLabel.stringValue = "\(transcriptionCount)"
        isExpanded = false
        clearTranscriptionItems()
    }

    @objc private func statsCardClicked() {
        if isExpanded {
            collapseStats()
        } else {
            expandStats()
        }
    }

    private func expandStats() {
        guard !recentTexts.isEmpty else { return }
        isExpanded = true

        let contentHeight = CGFloat(recentTexts.count) * itemHeight
        let visibleHeight = min(contentHeight, maxExpandedHeight)

        statsNumberLabel.isHidden = true
        statsDescLabel.isHidden = true
        statsClickButton.isHidden = true

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

            let newCardHeight = visibleHeight + 16
            let totalHeight = buttonHeight + dividerGap + newCardHeight
            window.animator().setContentSize(NSSize(width: expandedCardWidth, height: totalHeight))
            container.animator().frame = NSRect(x: 0, y: 0, width: expandedCardWidth, height: totalHeight)
            glassButton.animator().frame = NSRect(x: (expandedCardWidth - glassButton.frame.width) / 2, y: newCardHeight + dividerGap, width: glassButton.frame.width, height: buttonHeight)
            statsCard.animator().frame = NSRect(x: 0, y: 0, width: expandedCardWidth, height: newCardHeight)
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.createTranscriptionItems()
            }
        }
    }

    private func collapseStats() {
        isExpanded = false
        clearTranscriptionItems()

        let buttonWidth = padding + iconSize + spacing + label.frame.width + padding

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

            let totalHeight = buttonHeight + dividerGap + cardHeight
            window.animator().setContentSize(NSSize(width: buttonWidth, height: totalHeight))
            container.animator().frame = NSRect(x: 0, y: 0, width: buttonWidth, height: totalHeight)
            glassButton.animator().frame = NSRect(x: 0, y: cardHeight + dividerGap, width: buttonWidth, height: buttonHeight)
            statsCard.animator().frame = NSRect(x: 0, y: 0, width: buttonWidth, height: cardHeight)
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.statsNumberLabel.isHidden = false
                self.statsDescLabel.isHidden = false
                self.statsClickButton.isHidden = false
                self.statsNumberLabel.frame = NSRect(x: 0, y: self.cardHeight - 50, width: self.statsCard.frame.width, height: 40)
                self.statsDescLabel.frame = NSRect(x: 0, y: 14, width: self.statsCard.frame.width, height: 16)
                self.statsClickButton.frame = NSRect(x: 0, y: 0, width: self.statsCard.frame.width, height: self.cardHeight)
            }
        }
    }

    private func createTranscriptionItems() {
        let inset: CGFloat = 16
        let contentHeight = CGFloat(recentTexts.count) * itemHeight
        let visibleHeight = min(contentHeight, maxExpandedHeight)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 8, width: expandedCardWidth, height: visibleHeight))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay

        let documentView = NSView(frame: NSRect(x: 0, y: 0, width: expandedCardWidth, height: contentHeight))

        for (index, text) in recentTexts.enumerated() {
            let y = contentHeight - CGFloat(index + 1) * itemHeight
            let itemView = NSView(frame: NSRect(x: 0, y: y, width: expandedCardWidth, height: itemHeight))
            itemView.wantsLayer = true

            let charCount = text.count
            let badgeText = "\(charCount)"
            let badge = NSTextField(labelWithString: badgeText)
            badge.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
            badge.textColor = .secondaryLabelColor
            badge.backgroundColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.15)
            badge.wantsLayer = true
            badge.layer?.cornerRadius = 4
            badge.layer?.masksToBounds = true
            badge.alignment = .center
            badge.sizeToFit()
            let badgeWidth = max(badge.frame.width + 8, 32)
            badge.frame = NSRect(x: inset, y: (itemHeight - 14) / 2, width: badgeWidth, height: 14)

            let textX = inset + badgeWidth + 8
            let preview = text.replacingOccurrences(of: "\n", with: " ")

            let textLabel = NSTextField(wrappingLabelWithString: preview)
            textLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
            textLabel.textColor = .labelColor
            textLabel.backgroundColor = .clear
            textLabel.isBezeled = false
            textLabel.isEditable = false
            textLabel.isSelectable = false
            textLabel.maximumNumberOfLines = 3
            textLabel.lineBreakMode = .byTruncatingTail
            textLabel.cell?.wraps = true
            textLabel.cell?.isScrollable = false
            textLabel.preferredMaxLayoutWidth = expandedCardWidth - textX - inset
            textLabel.frame = NSRect(x: textX, y: 6, width: expandedCardWidth - textX - inset, height: itemHeight - 12)

            let copyButton = NSButton(frame: NSRect(x: 0, y: 0, width: expandedCardWidth, height: itemHeight))
            copyButton.title = ""
            copyButton.bezelStyle = .regularSquare
            copyButton.isBordered = false
            copyButton.isTransparent = true
            copyButton.target = self
            copyButton.action = #selector(copyTranscription(_:))
            copyButton.tag = index

            itemView.addSubview(badge)
            itemView.addSubview(textLabel)
            itemView.addSubview(copyButton)

            if index < recentTexts.count - 1 {
                let divider = NSView(frame: NSRect(x: inset, y: 0, width: expandedCardWidth - inset * 2, height: 0.5))
                divider.wantsLayer = true
                divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
                itemView.addSubview(divider)
            }

            documentView.addSubview(itemView)
            transcriptionItems.append(itemView)
        }

        scroll.documentView = documentView
        scroll.contentView.scroll(to: NSPoint(x: 0, y: contentHeight - visibleHeight))
        statsCard.addSubview(scroll)
        scrollView = scroll

        let dismiss = NSButton(frame: NSRect(x: expandedCardWidth - 32, y: visibleHeight - 16, width: 24, height: 24))
        dismiss.bezelStyle = .circular
        dismiss.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        dismiss.imagePosition = .imageOnly
        dismiss.isBordered = false
        dismiss.target = self
        dismiss.action = #selector(dismissClicked)
        statsCard.addSubview(dismiss)
        dismissButton = dismiss

        scroll.alphaValue = 0
        dismiss.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            scroll.animator().alphaValue = 1
            dismiss.animator().alphaValue = 1
        }
    }

    @objc private func dismissClicked() {
        collapseStats()
    }

    private func clearTranscriptionItems() {
        scrollView?.removeFromSuperview()
        scrollView = nil
        dismissButton?.removeFromSuperview()
        dismissButton = nil
        transcriptionItems.removeAll()
    }

    @objc private func copyTranscription(_ sender: NSButton) {
        guard sender.tag < recentTexts.count else { return }
        copyToPasteboard(recentTexts[sender.tag])
        collapseStats()
    }

    func showLoading() {
        stopAnimation()
        statsCard.isHidden = true
        label.isHidden = true
        updateGearIcon()

        let progressWidth: CGFloat = 120
        let buttonW = padding + iconSize + padding
        let totalWidth = max(buttonW, progressWidth)
        let totalHeight = buttonHeight + 16

        window.setContentSize(NSSize(width: totalWidth, height: totalHeight))
        container.frame = NSRect(x: 0, y: 0, width: totalWidth, height: totalHeight)
        glassButton.frame = NSRect(x: (totalWidth - buttonW) / 2, y: 16, width: buttonW, height: buttonHeight)
        clickButton.frame = NSRect(x: 0, y: 0, width: buttonW, height: buttonHeight)

        let bar = NSProgressIndicator(frame: NSRect(x: (totalWidth - progressWidth) / 2, y: 4, width: progressWidth, height: 4))
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = 0
        container.addSubview(bar)
        progressBar = bar

        show()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.rotationAngle -= 6
                self.updateGearIcon()
            }
        }
    }

    func updateLoadingProgress(_ progress: Double) {
        progressBar?.doubleValue = progress
    }

    func hideLoading() {
        stopAnimation()
        progressBar?.removeFromSuperview()
        progressBar = nil
        hide()
    }

    func showIdle() {
        stopAnimation()
        micIcon.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)
        micIcon.contentTintColor = .labelColor
        label.isHidden = false
        label.stringValue = "hold right ⌥ to dictate"
        label.sizeToFit()
        statsCard.isHidden = false
        resizeWindow(showStats: true)
        show()
    }

    private func updateGearIcon() {
        guard let baseImage = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil) else { return }
        let gearSize: CGFloat = 14
        let canvasSize = NSSize(width: iconSize, height: iconSize)
        let rotated = NSImage(size: canvasSize, flipped: false) { _ in
            NSGraphicsContext.current?.cgContext.translateBy(x: canvasSize.width / 2, y: canvasSize.height / 2)
            NSGraphicsContext.current?.cgContext.rotate(by: self.rotationAngle * .pi / 180)
            let gearRect = NSRect(x: -gearSize / 2, y: -gearSize / 2, width: gearSize, height: gearSize)
            baseImage.draw(in: gearRect)
            return true
        }
        rotated.isTemplate = true
        micIcon.image = rotated
        micIcon.contentTintColor = .secondaryLabelColor
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        rotationAngle = 0
        transcribeFrame = 0
    }

    func showRecording() {
        stopAnimation()
        glassButton.isHidden = true
        label.isHidden = true
        statsCard.isHidden = true
        queueCount += 1
        updateQueueCircles(recording: true)
        show()
    }

    func showTranscribing() {
        stopAnimation()
        hideLiveText()
        glassButton.isHidden = true
        label.isHidden = true
        statsCard.isHidden = true
        updateQueueCircles(recording: false)
        startTranscribeAnimation()
    }

    private func startTranscribeAnimation() {
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.transcribeFrame += 1
                self.updateFirstCircleIcon()
            }
        }
    }

    private func updateFirstCircleIcon() {
        guard !queueIcons.isEmpty else { return }
        let icons = ["ellipsis", "ellipsis", "sparkle", "ellipsis"]
        let icon = icons[transcribeFrame % icons.count]
        queueIcons[0].image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        queueIcons[0].contentTintColor = .secondaryLabelColor
    }

    private func updateQueueCircles(recording: Bool) {
        clearQueueCircles()

        let circlesWidth = CGFloat(queueCount) * circleSize + CGFloat(queueCount - 1) * circleGap
        let bubbleWidth: CGFloat = 320
        let bubbleHeight: CGFloat = liveTextBubble?.frame.height ?? 0
        let bubbleSpace: CGFloat = bubbleHeight > 0 ? bubbleHeight + 8 : 0
        let windowWidth = max(circlesWidth, circleSize, bubbleHeight > 0 ? bubbleWidth : 0)
        let totalHeight = circleSize + bubbleSpace

        window.setContentSize(NSSize(width: windowWidth, height: totalHeight))
        container.frame = NSRect(x: 0, y: 0, width: windowWidth, height: totalHeight)

        if let bubble = liveTextBubble {
            bubble.frame.origin = NSPoint(x: (windowWidth - bubbleWidth) / 2, y: 0)
        }

        let circleY = bubbleSpace
        for i in 0..<queueCount {
            let x = CGFloat(queueCount - 1 - i) * (circleSize + circleGap) + (windowWidth - circlesWidth) / 2
            let circle = NSVisualEffectView(frame: NSRect(x: x, y: circleY, width: circleSize, height: circleSize))
            circle.material = .hudWindow
            circle.state = .active
            circle.blendingMode = .behindWindow
            circle.wantsLayer = true
            circle.layer?.cornerRadius = circleSize / 2
            circle.layer?.masksToBounds = true
            circle.alphaValue = 0.6

            let iconView = NSImageView(frame: NSRect(x: (circleSize - 16) / 2, y: (circleSize - 16) / 2, width: 16, height: 16))
            iconView.imageScaling = .scaleProportionallyUpOrDown

            if i == 0 {
                if recording {
                    iconView.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)
                    iconView.contentTintColor = .labelColor
                } else {
                    iconView.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
                    iconView.contentTintColor = .secondaryLabelColor
                }
            } else {
                iconView.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)
                iconView.contentTintColor = .tertiaryLabelColor
            }

            circle.addSubview(iconView)
            container.addSubview(circle)
            queueCircles.append(circle)
            queueIcons.append(iconView)
        }

        if let screen = NSScreen.main {
            let x = (screen.frame.width - windowWidth) / 2
            let y = screen.frame.height * 0.6
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    private func clearQueueCircles() {
        queueCircles.forEach { $0.removeFromSuperview() }
        queueCircles.removeAll()
        queueIcons.removeAll()
    }

    func dequeueOne() {
        if queueCount > 0 {
            queueCount -= 1
        }
        hideLiveText()
    }

    func updateLiveText(_ text: String) {
        guard !text.isEmpty else { return }

        let bubbleWidth: CGFloat = 320
        let textPadding: CGFloat = 12
        let textWidth = bubbleWidth - textPadding * 2

        if liveTextBubble == nil {
            let bubble = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: bubbleWidth, height: 50))
            bubble.material = .hudWindow
            bubble.state = .active
            bubble.blendingMode = .behindWindow
            bubble.wantsLayer = true
            bubble.layer?.cornerRadius = 12
            bubble.layer?.masksToBounds = true
            bubble.alphaValue = 0.6

            let textLabel = NSTextField(wrappingLabelWithString: "")
            textLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
            textLabel.textColor = .labelColor
            textLabel.backgroundColor = .clear
            textLabel.isBezeled = false
            textLabel.isEditable = false
            textLabel.maximumNumberOfLines = 0
            textLabel.lineBreakMode = .byWordWrapping
            textLabel.preferredMaxLayoutWidth = textWidth
            textLabel.cell?.wraps = true

            bubble.addSubview(textLabel)
            container.addSubview(bubble)

            liveTextBubble = bubble
            liveTextLabel = textLabel
        }

        liveTextLabel?.stringValue = text
        liveTextLabel?.preferredMaxLayoutWidth = textWidth

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let textSize = liveTextLabel?.sizeThatFits(NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude)) ?? NSSize(width: textWidth, height: 20)
        let bubbleHeight = max(50, textSize.height + textPadding * 2)

        liveTextLabel?.frame = NSRect(x: textPadding, y: textPadding, width: textWidth, height: textSize.height)
        liveTextBubble?.frame.size.height = bubbleHeight

        let totalWidth = max(bubbleWidth, CGFloat(queueCount) * circleSize + CGFloat(queueCount - 1) * circleGap)
        let totalHeight = circleSize + 8 + bubbleHeight
        window.setContentSize(NSSize(width: totalWidth, height: totalHeight))
        container.frame = NSRect(x: 0, y: 0, width: totalWidth, height: totalHeight)

        let circleY = bubbleHeight + 8
        for (i, circle) in queueCircles.enumerated() {
            let x = CGFloat(queueCount - 1 - i) * (circleSize + circleGap) + (totalWidth - CGFloat(queueCount) * circleSize - CGFloat(queueCount - 1) * circleGap) / 2
            circle.frame.origin = NSPoint(x: x, y: circleY)
        }

        liveTextBubble?.frame.origin = NSPoint(x: (totalWidth - bubbleWidth) / 2, y: 0)

        if let screen = NSScreen.main {
            let x = (screen.frame.width - totalWidth) / 2
            window.setFrameOrigin(NSPoint(x: x, y: window.frame.origin.y))
        }

        CATransaction.commit()
    }

    func hideLiveText() {
        liveTextBubble?.removeFromSuperview()
        liveTextBubble = nil
        liveTextLabel = nil
    }

    func resetToIdle() {
        stopAnimation()
        queueCount = 0
        clearQueueCircles()
        hideLiveText()
        glassButton.isHidden = false
        hide()
    }

    private func resizeWindowIconOnly() {
        let buttonWidth = padding + iconSize + padding
        let totalHeight = buttonHeight
        window.setContentSize(NSSize(width: buttonWidth, height: totalHeight))
        container.frame = NSRect(x: 0, y: 0, width: buttonWidth, height: totalHeight)
        glassButton.frame = NSRect(x: 0, y: 0, width: buttonWidth, height: buttonHeight)
        clickButton.frame = NSRect(x: 0, y: 0, width: buttonWidth, height: buttonHeight)
        if let screen = NSScreen.main {
            let x = (screen.frame.width - buttonWidth) / 2
            window.setFrameOrigin(NSPoint(x: x, y: window.frame.origin.y))
        }
    }

    private func resizeWindow(showStats: Bool) {
        let buttonWidth = padding + iconSize + spacing + label.frame.width + padding
        let totalHeight = showStats ? buttonHeight + dividerGap + cardHeight : buttonHeight
        window.setContentSize(NSSize(width: buttonWidth, height: totalHeight))
        container.frame = NSRect(x: 0, y: 0, width: buttonWidth, height: totalHeight)
        glassButton.frame = NSRect(x: 0, y: showStats ? cardHeight + dividerGap : 0, width: buttonWidth, height: buttonHeight)
        label.frame.origin = NSPoint(x: padding + iconSize + spacing, y: (buttonHeight - label.frame.height) / 2)
        clickButton.frame = NSRect(x: 0, y: 0, width: buttonWidth, height: buttonHeight)
        statsCard.frame = NSRect(x: 0, y: 0, width: buttonWidth, height: cardHeight)
        statsNumberLabel.frame = NSRect(x: 0, y: cardHeight - 50, width: buttonWidth, height: 40)
        statsDescLabel.frame = NSRect(x: 0, y: 14, width: buttonWidth, height: 16)
        if let screen = NSScreen.main {
            let x = (screen.frame.width - buttonWidth) / 2
            window.setFrameOrigin(NSPoint(x: x, y: window.frame.origin.y))
        }
    }

    @objc private func recordClicked() {
        hide()
        onRecord()
    }

    func toggle() {
        window.isVisible ? hide() : showIdle()
    }

    func show() {
        guard let screen = NSScreen.main else { return }
        let x = (screen.frame.width - window.frame.width) / 2
        let y = screen.frame.height * 0.6
        window.setFrameOrigin(NSPoint(x: x, y: y))

        window.alphaValue = 0
        window.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            window.animator().alphaValue = 1
        }

        if let monitor = eventMonitor { NSEvent.removeMonitor(monitor) }
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hide()
        }
    }

    func hide() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }

        if isExpanded {
            isExpanded = false
            clearTranscriptionItems()
            statsNumberLabel.isHidden = false
            statsDescLabel.isHidden = false
            statsClickButton.isHidden = false

            let buttonWidth = padding + iconSize + spacing + label.frame.width + padding
            let totalHeight = buttonHeight + dividerGap + cardHeight
            window.setContentSize(NSSize(width: buttonWidth, height: totalHeight))
            container.frame = NSRect(x: 0, y: 0, width: buttonWidth, height: totalHeight)
            glassButton.frame = NSRect(x: 0, y: cardHeight + dividerGap, width: buttonWidth, height: buttonHeight)
            statsCard.frame = NSRect(x: 0, y: 0, width: buttonWidth, height: cardHeight)
            statsNumberLabel.frame = NSRect(x: 0, y: cardHeight - 50, width: buttonWidth, height: 40)
            statsDescLabel.frame = NSRect(x: 0, y: 14, width: buttonWidth, height: 16)
            statsClickButton.frame = NSRect(x: 0, y: 0, width: buttonWidth, height: cardHeight)
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            window.animator().alphaValue = 0
        }) { [weak self] in
            Task { @MainActor [weak self] in
                self?.window.orderOut(nil)
            }
        }
    }

    func showFileTranscribing(fileName: String) {
        stopAnimation()
        glassButton.isHidden = true
        statsCard.isHidden = true
        clearQueueCircles()
        hideLiveText()

        let bubbleWidth: CGFloat = 320
        let textPadding: CGFloat = 12

        let bubble = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: bubbleWidth, height: 60))
        bubble.material = .hudWindow
        bubble.state = .active
        bubble.blendingMode = .behindWindow
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 12
        bubble.layer?.masksToBounds = true
        bubble.alphaValue = 0.6

        let iconView = NSImageView(frame: NSRect(x: textPadding, y: 20, width: 20, height: 20))
        iconView.image = NSImage(systemSymbolName: "doc.fill", accessibilityDescription: nil)
        iconView.contentTintColor = .secondaryLabelColor
        iconView.imageScaling = .scaleProportionallyUpOrDown
        bubble.addSubview(iconView)

        var displayName = fileName
        if displayName.count > 30 { displayName = String(displayName.prefix(27)) + "..." }

        let nameLabel = NSTextField(labelWithString: displayName)
        nameLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        nameLabel.textColor = .labelColor
        nameLabel.frame = NSRect(x: textPadding + 28, y: 30, width: bubbleWidth - textPadding * 2 - 28, height: 18)
        bubble.addSubview(nameLabel)

        let statusLabel = NSTextField(labelWithString: "Transcribing...")
        statusLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: textPadding + 28, y: 12, width: bubbleWidth - textPadding * 2 - 28, height: 14)
        bubble.addSubview(statusLabel)

        container.addSubview(bubble)
        liveTextBubble = bubble

        window.setContentSize(NSSize(width: bubbleWidth, height: 60))
        container.frame = NSRect(x: 0, y: 0, width: bubbleWidth, height: 60)
        bubble.frame.origin = .zero

        show()
        startTranscribeAnimation()
    }

    func showFileResult(text: String, fileName: String) {
        stopAnimation()
        hideLiveText()

        let bubbleWidth: CGFloat = 320
        let textPadding: CGFloat = 12
        let textWidth = bubbleWidth - textPadding * 2

        let bubble = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: bubbleWidth, height: 100))
        bubble.material = .hudWindow
        bubble.state = .active
        bubble.blendingMode = .behindWindow
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 12
        bubble.layer?.masksToBounds = true
        bubble.alphaValue = 0.6

        var displayName = fileName
        if displayName.count > 35 { displayName = String(displayName.prefix(32)) + "..." }

        let headerLabel = NSTextField(labelWithString: displayName)
        headerLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        headerLabel.textColor = .secondaryLabelColor
        headerLabel.frame = NSRect(x: textPadding, y: 0, width: textWidth, height: 14)
        bubble.addSubview(headerLabel)

        let textLabel = NSTextField(wrappingLabelWithString: text)
        textLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        textLabel.textColor = .labelColor
        textLabel.backgroundColor = .clear
        textLabel.isBezeled = false
        textLabel.isEditable = false
        textLabel.maximumNumberOfLines = 6
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.preferredMaxLayoutWidth = textWidth

        let textSize = textLabel.sizeThatFits(NSSize(width: textWidth, height: 120))
        let bubbleHeight = min(textSize.height + 40, 160)

        textLabel.frame = NSRect(x: textPadding, y: 20, width: textWidth, height: bubbleHeight - 40)
        headerLabel.frame.origin.y = bubbleHeight - 18
        bubble.frame.size.height = bubbleHeight

        bubble.addSubview(textLabel)
        container.addSubview(bubble)
        liveTextBubble = bubble

        window.setContentSize(NSSize(width: bubbleWidth, height: bubbleHeight))
        container.frame = NSRect(x: 0, y: 0, width: bubbleWidth, height: bubbleHeight)

        if let screen = NSScreen.main {
            let x = (screen.frame.width - bubbleWidth) / 2
            window.setFrameOrigin(NSPoint(x: x, y: window.frame.origin.y))
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.queueCount == 0 else { return }
            self.resetToIdle()
        }
    }
}

extension Notification.Name {
    static let transcribeFile = Notification.Name("transcribeFile")
}

final class DropView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let types = sender.draggingPasteboard.types, types.contains(.fileURL) else { return [] }
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else { return false }
        let audioExtensions = ["m4a", "mp3", "wav", "ogg", "opus", "aiff", "aac", "flac"]
        for url in urls {
            if audioExtensions.contains(url.pathExtension.lowercased()) {
                NotificationCenter.default.post(name: .transcribeFile, object: url)
                return true
            }
        }
        return false
    }
}
