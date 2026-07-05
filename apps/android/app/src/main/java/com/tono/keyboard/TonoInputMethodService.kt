package com.tono.keyboard

import android.graphics.Color
import android.inputmethodservice.InputMethodService
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import com.tono.app.BuildConfig
import com.tono.app.net.ToneAnalysis
import com.tono.app.net.TonoApiClient
import com.tono.app.net.TonoApiException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import java.util.Locale

private enum class KeyboardMode { LETTERS, SYMBOLS }
private enum class ShiftState { NONE, SHIFT_ONCE, CAPS_LOCK }

/**
 * The Android analogue of KeyboardExtension/KeyboardRootView.swift: a
 * system-wide keyboard with a Coach button that analyzes whatever's already
 * typed in the focused field and lets the user tap a rewrite to replace it.
 *
 * Deliberately built with classic Android views (LinearLayout/Button/TextView)
 * rather than Compose. Hosting Compose inside an InputMethodService needs a
 * hand-rolled LifecycleOwner/ViewModelStoreOwner/SavedStateRegistryOwner —
 * doable, but another moving part this MVP doesn't need; the companion app
 * (MainActivity) is a normal Activity and uses Compose freely.
 *
 * Scope note: shift/caps-lock, a numbers/symbols layer, and sentence
 * auto-capitalization are implemented below. Full dictionary-based
 * autocorrect/word-suggestion is NOT — that needs a real dictionary asset
 * and a non-trivial matching algorithm, disproportionate to what this pass
 * needs (the product is a tone coach, not a keyboard-replacement pitch;
 * people can use their existing keyboard's autocorrect for typos and
 * switch to Tono for the Coach action). Bring it to full parity with the
 * iOS keyboard before this ships to users.
 */
class TonoInputMethodService : InputMethodService() {

    // BuildConfig fields are compile-time constants baked into the APK,
    // not runtime app state — the `:keyboard` process (see
    // AndroidManifest.xml) gets the identical value without any IPC, so
    // there's no reason for this to hardcode its own separate copy of
    // the same URL and risk drifting from what CoachViewModel uses.
    private val api = TonoApiClient(baseUrl = BuildConfig.TONO_API_URL)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    private lateinit var root: LinearLayout
    private lateinit var previewText: TextView
    private lateinit var resultContainer: LinearLayout
    private lateinit var coachButton: Button
    private lateinit var keysContainer: LinearLayout

    private var mode = KeyboardMode.LETTERS
    private var shiftState = ShiftState.NONE
    private var lastShiftTapAt = 0L

    private val letterRows = listOf("qwertyuiop", "asdfghjkl", "zxcvbnm")
    private val symbolRows = listOf("1234567890", "@#\$_&-+()/", "*\"':;!?")

    override fun onCreateInputView(): View {
        root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.parseColor("#1C1C20"))
            setPadding(dp(8), dp(8), dp(8), dp(8))
        }

        previewText = TextView(this).apply {
            setTextColor(Color.parseColor("#A0A0A8"))
            textSize = 12f
            maxLines = 2
            setPadding(dp(4), 0, dp(4), dp(4))
        }
        root.addView(previewText)

        coachButton = Button(this).apply {
            text = "Coach"
            setOnClickListener { onCoachTapped() }
        }
        root.addView(coachButton)

        resultContainer = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(
            ScrollView(this).apply {
                layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(140))
                addView(resultContainer)
            }
        )

        keysContainer = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(keysContainer)
        rebuildKeys()

        return root
    }

    override fun onStartInputView(info: EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        mode = KeyboardMode.LETTERS
        applyAutoCapitalizationIfNeeded()
        rebuildKeys()
    }

    /** Sentence-start / field-start auto-capitalization: if the cursor sits
     * at the very beginning of the field, or right after ". "/"! "/"? "
     * (or a newline), the next letter should come out capitalized without
     * the user having to reach for shift. */
    private fun applyAutoCapitalizationIfNeeded() {
        if (shiftState == ShiftState.CAPS_LOCK) return
        val before = currentInputConnection?.getTextBeforeCursor(2, 0)?.toString()
        val shouldCapitalize = before.isNullOrEmpty() ||
            before.endsWith("\n") ||
            Regex("""[.!?]\s$""").containsMatchIn(before)
        shiftState = if (shouldCapitalize) ShiftState.SHIFT_ONCE else ShiftState.NONE
    }

    private fun rebuildKeys() {
        keysContainer.removeAllViews()
        val rows = if (mode == KeyboardMode.LETTERS) letterRows else symbolRows

        rows.forEachIndexed { index, row ->
            val rowLayout = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER
            }
            val isLastLetterRow = mode == KeyboardMode.LETTERS && index == rows.lastIndex
            if (isLastLetterRow) {
                rowLayout.addView(keyButton(shiftLabel(), weight = 1.5f) { onShiftTapped() })
            }
            row.forEach { c ->
                val label = if (mode == KeyboardMode.LETTERS) applyCase(c.toString()) else c.toString()
                rowLayout.addView(keyButton(label) { onLetterOrSymbolTapped(label) })
            }
            if (isLastLetterRow) {
                rowLayout.addView(keyButton("⌫", weight = 1.5f) { deleteBackward() })
            }
            keysContainer.addView(rowLayout)
        }

        val bottomRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        if (mode == KeyboardMode.LETTERS) {
            bottomRow.addView(keyButton("123", weight = 1f) { mode = KeyboardMode.SYMBOLS; rebuildKeys() })
        } else {
            bottomRow.addView(keyButton("ABC", weight = 1f) { mode = KeyboardMode.LETTERS; rebuildKeys() })
            bottomRow.addView(keyButton("⌫", weight = 1f) { deleteBackward() })
        }
        bottomRow.addView(keyButton("space", weight = 3f) { onSpaceTapped() })
        bottomRow.addView(keyButton("⏎", weight = 1f) { onEnterTapped() })
        keysContainer.addView(bottomRow)
    }

    private fun shiftLabel(): String = when (shiftState) {
        ShiftState.NONE -> "⇧"
        ShiftState.SHIFT_ONCE -> "⬆"
        ShiftState.CAPS_LOCK -> "⇪"
    }

    private fun applyCase(letter: String): String =
        if (shiftState == ShiftState.NONE) letter.lowercase() else letter.uppercase()

    private fun onShiftTapped() {
        val now = System.currentTimeMillis()
        val isDoubleTap = (now - lastShiftTapAt) < 400
        lastShiftTapAt = now

        shiftState = when {
            isDoubleTap && shiftState == ShiftState.SHIFT_ONCE -> ShiftState.CAPS_LOCK
            shiftState == ShiftState.CAPS_LOCK -> ShiftState.NONE
            shiftState == ShiftState.NONE -> ShiftState.SHIFT_ONCE
            else -> ShiftState.NONE
        }
        rebuildKeys()
    }

    private fun onLetterOrSymbolTapped(label: String) {
        commit(label)
        if (mode == KeyboardMode.LETTERS && shiftState == ShiftState.SHIFT_ONCE) {
            shiftState = ShiftState.NONE
            rebuildKeys()
        }
    }

    private fun onSpaceTapped() {
        commit(" ")
        applyAutoCapitalizationIfNeeded()
        rebuildKeys()
    }

    private fun onEnterTapped() {
        commit("\n")
        applyAutoCapitalizationIfNeeded()
        rebuildKeys()
    }

    private fun keyButton(label: String, weight: Float = 1f, onClick: () -> Unit): Button =
        Button(this).apply {
            text = label
            textSize = 14f
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, weight)
            setOnClickListener { onClick() }
        }

    private fun commit(text: String) {
        currentInputConnection?.commitText(text, 1)
    }

    private fun deleteBackward() {
        currentInputConnection?.deleteSurroundingText(1, 0)
    }

    private fun onCoachTapped() {
        val ic = currentInputConnection ?: return
        val draft = ic.getTextBeforeCursor(MAX_DRAFT_CHARS, 0)?.toString().orEmpty()
        if (draft.isBlank()) return

        previewText.text = draft
        coachButton.isEnabled = false
        coachButton.text = "Analyzing…"

        scope.launch {
            try {
                val result = api.analyzePublic(
                    draft = draft,
                    mode = "coach",
                    locale = Locale.getDefault().toLanguageTag(),
                )
                renderResult(draft, result)
            } catch (e: TonoApiException) {
                renderMessage(e.message ?: "Something went wrong.")
            } catch (e: Exception) {
                renderMessage("Offline — check your connection and try again.")
            } finally {
                coachButton.isEnabled = true
                coachButton.text = "Coach"
            }
        }
    }

    private fun renderResult(originalDraft: String, result: ToneAnalysis) {
        resultContainer.removeAllViews()

        resultContainer.addView(
            TextView(this).apply {
                text = "${result.riskLevel.uppercase()} RISK — ${result.perception}"
                setTextColor(Color.WHITE)
                setPadding(dp(4), dp(4), dp(4), dp(4))
            }
        )

        result.suggestions.forEach { s ->
            resultContainer.addView(
                Button(this).apply {
                    text = "${s.axis}: ${s.text}"
                    isAllCaps = false
                    setOnClickListener { replaceDraft(originalDraft, s.text) }
                }
            )
        }
    }

    private fun renderMessage(message: String) {
        resultContainer.removeAllViews()
        resultContainer.addView(
            TextView(this).apply {
                text = message
                setTextColor(Color.parseColor("#DC2626"))
                setPadding(dp(4), dp(4), dp(4), dp(4))
            }
        )
    }

    private fun replaceDraft(originalDraft: String, rewrite: String) {
        val ic = currentInputConnection ?: return
        ic.deleteSurroundingText(originalDraft.length, 0)
        ic.commitText(rewrite, 1)
        resultContainer.removeAllViews()
        previewText.text = rewrite
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    private companion object {
        const val MAX_DRAFT_CHARS = 2000
    }
}
