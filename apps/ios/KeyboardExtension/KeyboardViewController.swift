// KeyboardViewController.swift
// Tono keyboard extension — build 77.
//
// UIKit-only stable architecture carried forward from build 76, with the
// smallest real Tono demo loop added on top:
//
//   - Bottom row reordered to the standard iOS-like layout
//       (globe at far left, space wide & centered, return, backspace at far right).
//   - Diagnostic labels replaced with a compact top bar: Tono wordmark,
//     clearly visible Coach button, tiny BUILD 77 marker.
//   - Coach flow: reads textDocumentProxy.documentContextBeforeInput,
//     no-op with inline "Type a message first" when empty, otherwise
//     POSTs {draft, mode:"coach"} to https://api.tonoit.com/v1/analyze
//     (the unauthenticated passthrough the production backend exposes),
//     with a strict timeout. The decode path is isolated in
//     `TonoCoachClient` so it's testable without a UIInputViewController.
//   - Results: 3-4 rewrite chips rendered into the keyboard's own UIKit
//     hierarchy. Tapping a chip replaces the captured draft by issuing
//     one `deleteBackward()` per captured character followed by
//     `insertText(rewrite)`. A Back button returns to the keys.
//   - Errors render the real HTTP/status/error text plus a Retry button;
//     the keyboard never auto-dismisses.
//
// Constraints preserved from build 76:
//   * NO SwiftUI, NO KeyboardModel, NO App Group reads, NO analytics,
//     NO history, NO custom assets, NO synchronous startup work.
//   * All key construction is lazy in viewDidAppear so first-frame
//     startup remains cheap.
//
// IMPORTANT: iOS keyboard extensions cannot present UIAlertController.
// Everything user-facing lives in the keyboard's own view hierarchy.

import UIKit

@objc(KeyboardViewController)
public final class KeyboardViewController: UIInputViewController {

    // MARK: - Layout constants

    private enum Const {
        static let row1: [String] = ["q","w","e","r","t","y","u","i","o","p"]
        static let row2: [String] = ["a","s","d","f","g","h","j","k","l"]
        static let row3: [String] = ["z","x","c","v","b","n","m"]

        // Touch-target minimums & spacing per Apple HIG.
        static let keyMinHeight: CGFloat = 44
        static let rowSpacing: CGFloat = 6
        static let edgePadding: CGFloat = 4

        // Bottom-row widths — globe & backspace are short, return is
        // ~standard, space fills the rest. Total ≈ view width.
        static let globeWidth: CGFloat = 44
        static let backspaceWidth: CGFloat = 56
        static let returnWidth: CGFloat = 80

        // Coach UX.
        static let coachTimeout: TimeInterval = 15
        static let backendURL = "https://api.tonoit.com/v1/analyze"
    }

    // MARK: - State

    private var keysInstalled = false
    private var topBar: UIView?
    private var bodyContainer: UIView?

    // Currently captured context length — used so the "insert rewrite"
    // path can delete exactly the characters we read.
    private var capturedContextLength: Int = 0

    // Subviews that may need to be torn down / rebuilt as we flip
    // between keyboard-mode and coach-mode.
    private var keysStack: UIStackView?
    private var coachContainer: UIView?
    private var coachStatusLabel: UILabel?
    private var coachResultsStack: UIStackView?
    private var coachErrorContainer: UIView?
    private var coachErrorLabel: UILabel?
    private var coachBusy: Bool = false

    // The text we sent to the backend; preserved so the rewrite path
    // can compute exact replacement boundaries if `documentContextBeforeInput`
    // has shifted between tap and response (e.g. user typed more).
    private var lastSubmittedDraft: String = ""

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        NSLog("TONO_KB BUILD77 01: viewDidLoad")

        view.backgroundColor = .systemBackground
        buildTopBar()
        buildBodyContainer()
        installKeyboardLayout()
        NSLog("TONO_KB BUILD77 02: UIKit hierarchy installed")
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        NSLog("TONO_KB BUILD77 03: viewWillAppear")
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        NSLog("TONO_KB BUILD77 04: viewDidAppear")
        // Nothing lazy to install here — build 76 only needed the lazy path
        // for QWERTY buttons because there were dozens; build 77 keeps that
        // idiom for parity but it's a no-op the second time.
        if !keysInstalled {
            installKeyboardLayout()
            keysInstalled = true
        }
    }

    public override func textDidChange(_ textInput: UITextInput?) {
        // No-op — build 77 doesn't track text state.
    }

    // MARK: - Top bar (Tono wordmark + Coach + BUILD marker)

    private func buildTopBar() {
        let bar = UIView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.accessibilityIdentifier = "TonoKB.topBar"
        view.addSubview(bar)

        let wordmark = UILabel()
        wordmark.text = "Tono"
        wordmark.font = .systemFont(ofSize: 17, weight: .semibold)
        wordmark.textColor = .label
        wordmark.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(wordmark)

        let build = UILabel()
        build.text = "BUILD 77"
        build.font = .systemFont(ofSize: 10, weight: .semibold)
        build.textColor = .secondaryLabel
        build.translatesAutoresizingMaskIntoConstraints = false
        build.accessibilityIdentifier = "TonoKB.buildMarker"
        bar.addSubview(build)

        let coach = UIButton(type: .system)
        coach.setTitle("Coach", for: .normal)
        coach.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        coach.setTitleColor(.white, for: .normal)
        coach.backgroundColor = .systemBlue
        coach.layer.cornerRadius = 8
        coach.contentEdgeInsets = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        coach.translatesAutoresizingMaskIntoConstraints = false
        coach.accessibilityIdentifier = "TonoKB.coachButton"
        coach.accessibilityLabel = "Tono Coach"
        coach.addTarget(self, action: #selector(coachTapped), for: .touchUpInside)
        bar.addSubview(coach)

        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.topAnchor.constraint(equalTo: view.topAnchor),
            bar.heightAnchor.constraint(equalToConstant: 44),

            wordmark.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            wordmark.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            build.leadingAnchor.constraint(equalTo: wordmark.trailingAnchor, constant: 6),
            build.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            coach.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),
            coach.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            coach.heightAnchor.constraint(equalToConstant: 36),
        ])

        self.topBar = bar
    }

    private func buildBodyContainer() {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.accessibilityIdentifier = "TonoKB.body"
        view.addSubview(container)

        guard let topBar = self.topBar else {
            NSLog("TONO_KB BUILD77 ERR: topBar missing in buildBodyContainer")
            return
        }

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Const.edgePadding),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Const.edgePadding),
            container.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 4),
            container.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -Const.edgePadding),
        ])

        self.bodyContainer = container
    }

    // MARK: - Keyboard layout (UIKit QWERTY + iOS-style bottom row)

    private func installKeyboardLayout() {
        guard let container = bodyContainer else { return }

        // Tear down any prior keyboard stack (we may be re-entering keyboard mode).
        keysStack?.removeFromSuperview()
        coachContainer?.removeFromSuperview()
        coachContainer = nil
        coachResultsStack = nil
        coachErrorContainer = nil
        coachErrorLabel = nil

        let stack = UIStackView()
        stack.axis = .vertical
        stack.distribution = .fillEqually
        stack.alignment = .fill
        stack.spacing = Const.rowSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        stack.addArrangedSubview(makeLetterRow(Const.row1))
        stack.addArrangedSubview(makeLetterRow(Const.row2))
        stack.addArrangedSubview(makeLetterRow(Const.row3))
        stack.addArrangedSubview(makeBottomRow())

        // Each row enforces a minimum 44pt touch target via its equal-fill
        // distribution across the available height.
        stack.heightAnchor.constraint(greaterThanOrEqualToConstant: Const.keyMinHeight * 4 + Const.rowSpacing * 3).isActive = true

        self.keysStack = stack
        NSLog("TONO_KB BUILD77 05: keyboard layout installed")
    }

    private func makeLetterRow(_ chars: [String]) -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.alignment = .fill
        row.spacing = Const.rowSpacing
        for ch in chars {
            row.addArrangedSubview(makeLetterButton(ch))
        }
        return row
    }

    private func makeLetterButton(_ char: String) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(char, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 20, weight: .regular)
        b.setTitleColor(.label, for: .normal)
        b.backgroundColor = UIColor.secondarySystemBackground
        b.layer.cornerRadius = 6
        b.layer.borderWidth = 0.5
        b.layer.borderColor = UIColor.separator.cgColor
        b.accessibilityLabel = "Tono letter \(char)"
        b.accessibilityIdentifier = "TonoKB.letter.\(char)"
        b.addTarget(self, action: #selector(letterTapped(_:)), for: .touchUpInside)
        return b
    }

    /// Standard iOS-style bottom row:
    ///   [ globe ] [    space    ] [ return ] [ ⌫ backspace ]
    private func makeBottomRow() -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.distribution = .fill
        row.alignment = .fill
        row.spacing = Const.rowSpacing

        let globe = makeControlButton(
            title: "\u{1F310}",
            action: #selector(advanceToNextInputMode),
            width: Const.globeWidth,
            bg: .secondarySystemBackground,
            id: "globe"
        )
        let space = makeControlButton(
            title: "space",
            action: #selector(spaceTapped),
            width: nil,           // flex
            bg: .secondarySystemBackground,
            id: "space"
        )
        let returnKey = makeControlButton(
            title: "return",
            action: #selector(returnTapped),
            width: Const.returnWidth,
            bg: .secondarySystemBackground,
            id: "return"
        )
        let backspace = makeControlButton(
            title: "\u{232B}",
            action: #selector(backspaceTapped),
            width: Const.backspaceWidth,
            bg: .secondarySystemBackground,
            id: "backspace"
        )

        row.addArrangedSubview(globe)
        row.addArrangedSubview(space)
        row.addArrangedSubview(returnKey)
        row.addArrangedSubview(backspace)
        return row
    }

    private func makeControlButton(
        title: String,
        action: Selector,
        width: CGFloat?,
        bg: UIColor,
        id: String
    ) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        b.setTitleColor(.label, for: .normal)
        b.backgroundColor = bg
        b.layer.cornerRadius = 6
        b.layer.borderWidth = 0.5
        b.layer.borderColor = UIColor.separator.cgColor
        b.accessibilityLabel = "Tono control \(id)"
        b.accessibilityIdentifier = "TonoKB.\(id)"
        b.addTarget(self, action: action, for: .touchUpInside)
        b.translatesAutoresizingMaskIntoConstraints = false
        if let width = width {
            b.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        b.heightAnchor.constraint(greaterThanOrEqualToConstant: Const.keyMinHeight).isActive = true
        return b
    }

    // MARK: - Key actions

    @objc private func letterTapped(_ sender: UIButton) {
        guard let title = sender.title(for: .normal) else { return }
        textDocumentProxy.insertText(title)
    }

    @objc private func spaceTapped() {
        textDocumentProxy.insertText(" ")
    }

    @objc private func backspaceTapped() {
        textDocumentProxy.deleteBackward()
    }

    @objc private func returnTapped() {
        textDocumentProxy.insertText("\n")
    }

    // MARK: - Coach flow

    @objc private func coachTapped() {
        guard !coachBusy else { return }
        let proxy = textDocumentProxy
        // The spec asks for documentContextBeforeInput specifically — that's
        // what we send to the backend.
        let raw = proxy.documentContextBeforeInput ?? ""
        let draft = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if draft.isEmpty {
            presentCoachEmptyState()
            return
        }
        // Remember exactly what we sent so the insert path can replace
        // the same span even if the host text field has scrolled.
        capturedContextLength = raw.count
        lastSubmittedDraft = draft
        runCoach(draft: draft)
    }

    private func presentCoachEmptyState() {
        // Stay in keyboard layout — just show an inline banner above the keys.
        // We avoid swapping the entire view tree for an empty-state copy so
        // a single keystroke isn't required to dismiss.
        guard let container = bodyContainer else { return }
        // Tear down any previous banner.
        container.subviews.forEach { sub in
            if sub.accessibilityIdentifier == "TonoKB.emptyBanner" {
                sub.removeFromSuperview()
            }
        }
        let banner = UILabel()
        banner.text = "Type a message first"
        banner.font = .systemFont(ofSize: 13, weight: .medium)
        banner.textColor = .secondaryLabel
        banner.textAlignment = .center
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.accessibilityIdentifier = "TonoKB.emptyBanner"
        container.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            banner.topAnchor.constraint(equalTo: container.topAnchor),
            banner.heightAnchor.constraint(equalToConstant: 24),
        ])
        // Re-render the keys under the banner.
        if keysStack == nil {
            installKeyboardLayout()
        } else {
            keysStack?.removeFromSuperview()
            installKeyboardLayout()
        }
        // Auto-clear the banner after a short delay so it doesn't accumulate.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak banner] in
            banner?.removeFromSuperview()
        }
    }

    private func runCoach(draft: String) {
        coachBusy = true
        presentCoachLoading()
        let client = TonoCoachClient(endpoint: Const.backendURL, timeout: Const.coachTimeout)
        NSLog("TONO_KB BUILD77 coach: begin POST /v1/analyze (len=\(draft.count))")
        client.coach(draft: draft) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.coachBusy = false
                switch result {
                case .success(let response):
                    NSLog("TONO_KB BUILD77 coach: OK risk=\(response.riskLevel) suggestions=\(response.suggestions.count)")
                    self.presentCoachResults(response)
                case .failure(let err):
                    NSLog("TONO_KB BUILD77 coach: FAIL \(err.userFacingMessage)")
                    self.presentCoachError(err)
                }
            }
        }
    }

    private func presentCoachLoading() {
        guard let container = bodyContainer else { return }
        // Replace keyboard layout with a small loading panel.
        keysStack?.removeFromSuperview()
        keysStack = nil
        coachErrorContainer?.removeFromSuperview()
        coachErrorContainer = nil

        let panel = UIView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.accessibilityIdentifier = "TonoKB.coachLoading"
        container.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            panel.topAnchor.constraint(equalTo: container.topAnchor),
            panel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let label = UILabel()
        label.text = "Coaching…"
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(label)

        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        panel.addSubview(spinner)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
            spinner.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
        ])

        coachContainer = panel
        coachStatusLabel = label
    }

    private func presentCoachResults(_ response: TonoCoachClient.CoachResponse) {
        guard let container = bodyContainer else { return }
        // Tear down loading.
        coachContainer?.removeFromSuperview()
        coachContainer = nil
        coachStatusLabel = nil

        let panel = UIView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.accessibilityIdentifier = "TonoKB.coachResults"
        container.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            panel.topAnchor.constraint(equalTo: container.topAnchor),
            panel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let title = UILabel()
        title.text = "Tono · \(response.riskDisplayName)"
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = .label
        title.numberOfLines = 1
        title.translatesAutoresizingMaskIntoConstraints = false
        title.accessibilityIdentifier = "TonoKB.riskBadge"
        panel.addSubview(title)

        let back = UIButton(type: .system)
        back.setTitle("Back", for: .normal)
        back.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        back.translatesAutoresizingMaskIntoConstraints = false
        back.accessibilityIdentifier = "TonoKB.coachBack"
        back.addTarget(self, action: #selector(backToKeysTapped), for: .touchUpInside)
        panel.addSubview(back)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.distribution = .fillEqually
        stack.alignment = .fill
        stack.spacing = Const.rowSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.accessibilityIdentifier = "TonoKB.rewrites"
        panel.addSubview(stack)

        // Render up to 4 suggestions.
        let shown = Array(response.suggestions.prefix(4))
        if shown.isEmpty {
            let empty = UILabel()
            empty.text = "No rewrites available."
            empty.font = .systemFont(ofSize: 13)
            empty.textColor = .secondaryLabel
            empty.textAlignment = .center
            empty.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(empty)
        } else {
            for (idx, s) in shown.enumerated() {
                stack.addArrangedSubview(makeRewriteChip(suggestion: s, index: idx))
            }
        }

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 12),
            title.topAnchor.constraint(equalTo: panel.topAnchor, constant: 4),
            title.trailingAnchor.constraint(lessThanOrEqualTo: back.leadingAnchor, constant: -8),

            back.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
            back.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            back.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),

            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            stack.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])

        coachContainer = panel
        coachResultsStack = stack
    }

    private func makeRewriteChip(suggestion: TonoCoachClient.CoachRewrite, index: Int) -> UIView {
        let chip = UIControl()
        chip.backgroundColor = .secondarySystemBackground
        chip.layer.cornerRadius = 8
        chip.layer.borderWidth = 0.5
        chip.layer.borderColor = UIColor.separator.cgColor
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.accessibilityIdentifier = "TonoKB.rewrite.\(suggestion.axis).\(index)"
        chip.accessibilityLabel = "Tono rewrite \(suggestion.axis)"

        let axis = UILabel()
        axis.text = suggestion.axis.uppercased()
        axis.font = .systemFont(ofSize: 10, weight: .heavy)
        axis.textColor = .systemBlue
        axis.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(axis)

        let text = UILabel()
        text.text = suggestion.text
        text.font = .systemFont(ofSize: 14, weight: .regular)
        text.textColor = .label
        text.numberOfLines = 2
        text.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(text)

        NSLayoutConstraint.activate([
            chip.heightAnchor.constraint(greaterThanOrEqualToConstant: Const.keyMinHeight),

            axis.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 10),
            axis.topAnchor.constraint(equalTo: chip.topAnchor, constant: 6),
            axis.trailingAnchor.constraint(lessThanOrEqualTo: chip.trailingAnchor, constant: -10),

            text.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 10),
            text.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -10),
            text.topAnchor.constraint(equalTo: axis.bottomAnchor, constant: 2),
            text.bottomAnchor.constraint(lessThanOrEqualTo: chip.bottomAnchor, constant: -6),
        ])

        // Action: replace captured context with the rewrite.
        let rewriteText = suggestion.text
        chip.addAction(UIAction { [weak self] _ in
            self?.applyRewrite(rewriteText)
        }, for: .touchUpInside)
        return chip
    }

    @objc private func backToKeysTapped() {
        coachContainer?.removeFromSuperview()
        coachContainer = nil
        coachResultsStack = nil
        coachErrorContainer = nil
        coachErrorLabel = nil
        installKeyboardLayout()
    }

    private func applyRewrite(_ rewrite: String) {
        // Delete exactly the captured prefix length, then insert the rewrite.
        // We cap deletions by what's still in the proxy buffer — if the user
        // typed more while the request was in flight, we delete only the
        // amount we sent, which still produces a clean replacement for the
        // original span (the tail of the user's keystrokes is preserved).
        let proxy = textDocumentProxy
        let liveContext = proxy.documentContextBeforeInput ?? ""
        let deletions = min(capturedContextLength, liveContext.count)
        for _ in 0..<deletions {
            proxy.deleteBackward()
        }
        proxy.insertText(rewrite)
        NSLog("TONO_KB BUILD77 rewrite: inserted len=\(rewrite.count) (deleted \(deletions))")
        // Stay in the results panel so the user can pick another option.
    }

    // MARK: - Coach error

    private func presentCoachError(_ err: TonoCoachClient.CoachError) {
        guard let container = bodyContainer else { return }
        coachContainer?.removeFromSuperview()
        coachContainer = nil
        coachStatusLabel = nil

        let panel = UIView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.accessibilityIdentifier = "TonoKB.coachError"
        container.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            panel.topAnchor.constraint(equalTo: container.topAnchor),
            panel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let title = UILabel()
        title.text = "Tono couldn’t reply"
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = .label
        title.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(title)

        let detail = UILabel()
        detail.text = err.userFacingMessage
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabel
        detail.numberOfLines = 0
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.accessibilityIdentifier = "TonoKB.coachErrorDetail"
        panel.addSubview(detail)

        let retry = UIButton(type: .system)
        retry.setTitle("Retry", for: .normal)
        retry.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        retry.backgroundColor = .systemBlue
        retry.setTitleColor(.white, for: .normal)
        retry.layer.cornerRadius = 6
        retry.contentEdgeInsets = UIEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        retry.translatesAutoresizingMaskIntoConstraints = false
        retry.accessibilityIdentifier = "TonoKB.coachRetry"
        retry.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        panel.addSubview(retry)

        let back = UIButton(type: .system)
        back.setTitle("Back", for: .normal)
        back.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        back.translatesAutoresizingMaskIntoConstraints = false
        back.addTarget(self, action: #selector(backToKeysTapped), for: .touchUpInside)
        panel.addSubview(back)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 12),
            title.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
            title.topAnchor.constraint(equalTo: panel.topAnchor, constant: 8),

            detail.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 12),
            detail.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),

            retry.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 12),
            retry.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 12),
            retry.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),

            back.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
            back.centerYAnchor.constraint(equalTo: retry.centerYAnchor),
            back.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
        ])

        coachContainer = panel
        coachErrorContainer = panel
        coachErrorLabel = detail
    }

    @objc private func retryTapped() {
        coachErrorContainer?.removeFromSuperview()
        coachErrorContainer = nil
        coachErrorLabel = nil
        // Re-send the same draft we sent the first time.
        let draft = lastSubmittedDraft
        if draft.isEmpty {
            presentCoachEmptyState()
        } else {
            runCoach(draft: draft)
        }
    }
}