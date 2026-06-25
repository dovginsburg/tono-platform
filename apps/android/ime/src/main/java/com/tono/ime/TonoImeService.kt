package com.tono.ime

import android.inputmethodservice.InputMethodService
import android.text.InputType
import android.view.View
import android.view.inputmethod.EditorInfo
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.platform.ViewCompositionStrategy
import androidx.lifecycle.*
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.lifecycle.viewmodel.compose.LocalViewModelStoreOwner
import androidx.savedstate.SavedStateRegistry
import androidx.savedstate.SavedStateRegistryController
import androidx.savedstate.SavedStateRegistryOwner
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
        lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_RESUME)
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
        lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_PAUSE)
        super.onFinishInputView(finishingInput)
    }

    override fun onDestroy() {
        lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_DESTROY)
        _viewModelStore.clear()
        super.onDestroy()
    }

    // ─── Input view ────────────────────────────────────────────────────────

    override fun onCreateInputView(): View {
        return ComposeView(this).apply {
            setViewCompositionStrategy(ViewCompositionStrategy.DisposeOnDetachedFromWindow)
            setContent {
                CompositionLocalProvider(
                    LocalLifecycleOwner provides this@TonoImeService,
                    LocalViewModelStoreOwner provides this@TonoImeService,
                ) {
                    KeyboardScreen(
                        viewModel        = viewModel,
                        draft            = viewModel.draft.value,
                        onInsertText     = ::insertFullText,
                        onDeleteBackward = { currentInputConnection?.deleteSurroundingText(1, 0) },
                        onInsertSpace    = { currentInputConnection?.commitText(" ", 1) },
                        onSwitchIme      = { switchToNextInputMethod(false) },
                    )
                }
            }
        }
    }

    // Secure fields (passwords, banking) block text reading — same constraint as iOS.
    override fun onStartInput(attribute: EditorInfo?, restarting: Boolean) {
        super.onStartInput(attribute, restarting)
        val inputType = attribute?.inputType ?: return
        val variation = inputType and InputType.TYPE_MASK_VARIATION
        val isSecure = variation == InputType.TYPE_TEXT_VARIATION_PASSWORD ||
                       variation == InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD ||
                       variation == InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD ||
                       variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD
        if (isSecure) viewModel.goBack()
    }

    // ─── Private helpers ───────────────────────────────────────────────────

    private fun syncDraftFromEditor() {
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
}
