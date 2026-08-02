package com.tono.ime

import android.content.Context
import android.inputmethodservice.InputMethodService
import android.os.Build
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.platform.ViewCompositionStrategy
import androidx.lifecycle.*
import androidx.savedstate.SavedStateRegistry
import androidx.savedstate.SavedStateRegistryController
import androidx.savedstate.SavedStateRegistryOwner
import androidx.savedstate.setViewTreeSavedStateRegistryOwner
import com.tono.ime.keyboard.EditorPolicies
import com.tono.ime.ui.KeyboardScreen
import com.tono.shared.analytics.CrashReporter
import com.tono.shared.storage.SharedKeys
import com.tono.shared.storage.SharedStore

// Mirrors ios/KeyboardExtension/ — UIInputViewController equivalent.
// Implements LifecycleOwner + SavedStateRegistryOwner + ViewModelStoreOwner
// so Compose and ViewModel work correctly inside a Service context.

class TonoImeService : InputMethodService(),
    LifecycleOwner,
    SavedStateRegistryOwner,
    ViewModelStoreOwner {

    // ─── Lifecycle wiring ──────────────────────────────────────────────────

    private val lifecycleRegistry = LifecycleRegistry(this)
    private val savedStateController = SavedStateRegistryController.create(this)
    private val _viewModelStore = ViewModelStore()

    override val lifecycle: Lifecycle get() = lifecycleRegistry
    override val savedStateRegistry: SavedStateRegistry get() = savedStateController.savedStateRegistry
    override val viewModelStore: ViewModelStore get() = _viewModelStore

    private lateinit var viewModel: CoachViewModel

    // Whether the focused field wants sentence auto-capitalization. Read once per
    // field in onStartInput so keystroke handlers don't re-derive it.
    private var autoCapEnabled = false

    // ─── Service lifecycle ─────────────────────────────────────────────────

    override fun onCreate() {
        super.onCreate()
        savedStateController.performAttach()
        savedStateController.performRestore(null)
        lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_CREATE)

        viewModel = ViewModelProvider(this)[CoachViewModel::class.java]

        SharedStore.putBoolean(SharedKeys.KEYBOARD_LOADED, true)
        CrashReporter.configure(this)
    }

    override fun onStartInputView(info: EditorInfo, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        lifecycleRegistry.currentState = Lifecycle.State.RESUMED
        syncDraftFromEditor()
    }

    override fun onUpdateSelection(
        oldSelStart: Int, oldSelEnd: Int,
        newSelStart: Int, newSelEnd: Int,
        candidatesStart: Int, candidatesEnd: Int,
    ) {
        super.onUpdateSelection(oldSelStart, oldSelEnd, newSelStart, newSelEnd, candidatesStart, candidatesEnd)
        syncDraftFromEditor()
    }

    override fun onFinishInputView(finishingInput: Boolean) {
        lifecycleRegistry.currentState = Lifecycle.State.CREATED
        super.onFinishInputView(finishingInput)
    }

    override fun onDestroy() {
        lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_DESTROY)
        _viewModelStore.clear()
        super.onDestroy()
    }

    // ─── Input view ────────────────────────────────────────────────────────

    override fun onCreateInputView(): View {
        /*
         * InputMethodService inserts this view below its own parentPanel. Compose
         * creates the window recomposer from that framework-owned parent, so
         * owners installed only on the returned ComposeView are not visible to
         * the lookup that runs while parentPanel is attaching (Build 117's P0).
         *
         * Install the service owners at the IME window root before returning the
         * input view. Every framework and app-owned descendant then resolves the
         * same lifecycle, saved-state registry, and ViewModel store.
         */
        val decorView = requireNotNull(window?.window?.decorView) {
            "InputMethodService window must exist before creating its input view"
        }
        decorView.setViewTreeLifecycleOwner(this)
        decorView.setViewTreeViewModelStoreOwner(this)
        decorView.setViewTreeSavedStateRegistryOwner(this)

        return ComposeView(this).apply {
            setViewCompositionStrategy(ViewCompositionStrategy.DisposeOnDetachedFromWindow)
            // Also support direct attachment in previews and regression harnesses.
            setViewTreeLifecycleOwner(this@TonoImeService)
            setViewTreeViewModelStoreOwner(this@TonoImeService)
            setViewTreeSavedStateRegistryOwner(this@TonoImeService)
            setContent {
                KeyboardScreen(
                    viewModel        = viewModel,
                    draft            = viewModel.draft.value,
                    onKey            = ::onCharacterKey,
                    onShift          = { viewModel.onShiftKey() },
                    onSwitchLayer    = { viewModel.onSwitchLayer() },
                    onDeleteBackward = ::onBackspace,
                    onReturn         = ::onReturn,
                    onInsertText     = ::insertFullText,
                    onSwitchIme      = ::switchToNextIme,
                )
            }
        }
    }

    // Configure the keyboard for the newly focused field. Typing works in every
    // field, including secure ones; only the field-reading Coach/Read features
    // fail closed in password/PIN fields — same posture as iOS.
    override fun onStartInput(attribute: EditorInfo?, restarting: Boolean) {
        super.onStartInput(attribute, restarting)
        val inputType = attribute?.inputType ?: 0
        val imeOptions = attribute?.imeOptions ?: 0
        val secure = EditorPolicies.isSecureField(inputType)
        autoCapEnabled = EditorPolicies.autoCapEnabled(inputType)
        viewModel.onFieldStarted(
            autoCap     = autoCapEnabled,
            secure      = secure,
            returnLabel = EditorPolicies.returnLabel(imeOptions),
        )
    }

    // ─── Typing (InputConnection) ──────────────────────────────────────────

    // A single tapped character key. The ViewModel applies shift/layer casing;
    // the resulting character is committed locally and never leaves the device.
    private fun onCharacterKey(key: String) {
        val ic = currentInputConnection ?: return
        ic.commitText(viewModel.onCharacterKey(key), 1)
        // Re-arm sentence auto-cap only at word boundaries so a manually held
        // shift mid-word is never stomped.
        if (key == " ") reArmAutoCap(ic)
    }

    private fun onBackspace() {
        val ic = currentInputConnection ?: return
        val selected = ic.getSelectedText(0)
        if (!selected.isNullOrEmpty()) {
            // Replace an active selection with nothing, matching platform delete.
            ic.commitText("", 1)
        } else {
            ic.deleteSurroundingText(1, 0)
        }
    }

    // Return key: perform the host's editor action (Go/Search/Send/…) when it
    // asks for one, otherwise insert a newline. Mirrors iOS returnKeySpec.
    private fun onReturn() {
        val ic = currentInputConnection ?: return
        val action = EditorPolicies.returnAction(currentInputEditorInfo?.imeOptions ?: 0)
        if (action != null) {
            ic.performEditorAction(action)
        } else {
            ic.commitText("\n", 1)
            reArmAutoCap(ic)
        }
    }

    // Reads at most the two characters before the cursor to decide whether the
    // next letter should auto-capitalize. Nothing is retained, logged, or sent.
    private fun reArmAutoCap(ic: InputConnection) {
        if (!autoCapEnabled) return
        val before = ic.getTextBeforeCursor(2, 0)?.toString() ?: ""
        viewModel.onAutoCapitalize(before)
    }

    // ─── Private helpers ───────────────────────────────────────────────────

    private fun syncDraftFromEditor() {
        // Never pull the field contents in a secure context, even for the local
        // draft preview — password/PIN text stays untouched. Typing still works.
        if (viewModel.secureField.value) return
        val ic = currentInputConnection ?: return
        val before = ic.getTextBeforeCursor(500, 0)?.toString() ?: ""
        val after  = ic.getTextAfterCursor(500, 0)?.toString() ?: ""
        viewModel.onDraftChanged((before + after).trim())
    }

    private fun insertFullText(text: String) {
        val ic = currentInputConnection ?: return
        // Select all existing text and replace with the rewrite
        ic.performContextMenuAction(android.R.id.selectAll)
        ic.commitText(text, 1)
    }

    /// Hand off to the next input method (the globe key).
    ///
    /// `InputMethodService.switchToNextInputMethod` only exists from API 28, but
    /// this module ships `minSdk = 26`. Calling it unguarded threw
    /// `NoSuchMethodError` and killed the keyboard process on Android 8.0/8.1 —
    /// the user tapped the globe and the keyboard vanished mid-sentence, with no
    /// way back except reopening the field. Lint caught it as a `NewApi` error.
    ///
    /// Below API 28 we use the `InputMethodManager` overload (API 16+,
    /// deprecated in 28 precisely because the service method replaced it),
    /// which needs the IME window token. If the token is unavailable the switch
    /// is a no-op rather than a crash — a globe tap that does nothing is far
    /// better than a keyboard that disappears.
    private fun switchToNextIme() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            switchToNextInputMethod(false)
            return
        }
        val token = window?.window?.attributes?.token ?: return
        val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager ?: return
        @Suppress("DEPRECATION")
        imm.switchToNextInputMethod(token, false)
    }
}
