package com.tono.ime

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.tono.shared.analytics.AnalyticsEvent
import com.tono.shared.analytics.CrashReporter
import com.tono.shared.analytics.TonoAnalytics
import com.tono.shared.engine.MockToneAnalyzer
import com.tono.shared.models.AnalysisMode
import com.tono.shared.models.AnalysisRequest
import com.tono.shared.models.RewriteAxis
import com.tono.shared.models.RewriteSuggestion
import com.tono.shared.models.ToneAnalysis
import com.tono.shared.models.ToneEngineError
import com.tono.shared.network.TonoBackend
import com.tono.shared.storage.Recipient
import com.tono.shared.storage.RecipientMemory
import com.tono.shared.storage.SharedKeys
import com.tono.shared.storage.SharedStore
import com.tono.shared.storage.StyleMemory
import com.tono.shared.storage.UserMemory
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

// Mirrors the KeyboardModel in ios/KeyboardExtension/KeyboardRootView.swift

sealed class KeyboardMode {
    object Keyboard : KeyboardMode()
    object Loading : KeyboardMode()
    data class Results(val analysis: ToneAnalysis, val mode: AnalysisMode) : KeyboardMode()
    data class Error(val message: String) : KeyboardMode()
}

class CoachViewModel : ViewModel() {

    private val _mode = MutableStateFlow<KeyboardMode>(KeyboardMode.Keyboard)
    val mode: StateFlow<KeyboardMode> = _mode

    private val _draft = MutableStateFlow("")
    val draft: StateFlow<String> = _draft

    private val _isPro = MutableStateFlow(SharedStore.getBoolean(SharedKeys.PRO_UNLOCKED))
    val isPro: StateFlow<Boolean> = _isPro

    // Recipient picker — loaded when the keyboard opens, toggled by the chip row
    private val _recipients = MutableStateFlow<List<Recipient>>(emptyList())
    val recipients: StateFlow<List<Recipient>> = _recipients

    private val _selectedRecipient = MutableStateFlow<Recipient?>(null)
    val selectedRecipient: StateFlow<Recipient?> = _selectedRecipient

    // C4: detect edit-after-insert
    private var lastInsertedRewrite: String? = null
    private var coachTapTime: Long = 0L

    // Collective improvement: context captured when real results arrive.
    private data class OutcomeContext(val riskLevel: String, val mode: String, val msgLenBucket: String)
    private var pendingOutcome: OutcomeContext? = null

    init {
        _recipients.value = RecipientMemory.all()
    }

    // Toggle: tap same recipient again to deselect
    fun selectRecipient(recipient: Recipient) {
        _selectedRecipient.value =
            if (_selectedRecipient.value?.id == recipient.id) null else recipient
    }

    // Called by the IME service whenever the text field content changes
    fun onDraftChanged(newDraft: String) {
        val prev = _draft.value
        _draft.value = newDraft

        // C4: if draft changed after an insert, that's an edit-after-insert
        lastInsertedRewrite?.let { inserted ->
            if (newDraft.isNotEmpty() && newDraft != inserted && prev == inserted) {
                TonoAnalytics.track(AnalyticsEvent.RewriteEditedAfterInsert)
                lastInsertedRewrite = null
            }
        }
    }

    fun runCoach() {
        val text = _draft.value.trim()
        if (text.isEmpty()) return

        val recipient = _selectedRecipient.value

        coachTapTime = System.currentTimeMillis()
        TonoAnalytics.track(AnalyticsEvent.CoachRequested("coach"))
        CrashReporter.addBreadcrumb("Coach tapped")
        CrashReporter.setCustomKey("loading", "keyboard_mode")
        CrashReporter.setCustomKey(true, "network_in_flight")

        val hints = UserMemory.contextHints()
        CrashReporter.setCustomKey(hints.isNotEmpty(), "memory_facts_loaded")
        if (recipient != null) CrashReporter.setCustomKey(recipient.label, "recipient_selected")

        val req = AnalysisRequest(
            draft         = text,
            recipientHint = recipient?.voiceHint,
            contextHints  = hints,
            mode          = AnalysisMode.COACH,
        )

        // Show mock preview immediately (latency mask)
        val preview = MockToneAnalyzer.analyze(req)
        _mode.value = KeyboardMode.Results(preview, AnalysisMode.COACH)
        val mockMs = (System.currentTimeMillis() - coachTapTime).toInt()
        TonoAnalytics.track(AnalyticsEvent.AnalysisShown(preview.riskLevel.value, mockMs, "mock"))
        CrashReporter.setCustomKey("results_mock", "keyboard_mode")

        viewModelScope.launch {
            runCatching {
                TonoBackend.analyze(
                    text          = text,
                    contextHints  = hints.takeIf { it.isNotEmpty() },
                    recipientHint = recipient?.voiceHint,
                    axes          = StyleMemory.rankedAxes(recipient?.id),
                    mode          = AnalysisMode.COACH,
                )
            }.fold(
                onSuccess = { result ->
                    _mode.value = KeyboardMode.Results(result, AnalysisMode.COACH)
                    val llmMs = (System.currentTimeMillis() - coachTapTime).toInt()
                    TonoAnalytics.track(AnalyticsEvent.AnalysisShown(result.riskLevel.value, llmMs, "llm"))
                    CrashReporter.setCustomKey("results_real", "keyboard_mode")
                    CrashReporter.setCustomKey(false, "network_in_flight")
                    pendingOutcome = OutcomeContext(result.riskLevel.value, "coach", msgLenBucket(text))
                },
                onFailure = { err ->
                    CrashReporter.setCustomKey(false, "network_in_flight")
                    // C2: fail honestly — never leave mock as terminal verdict
                    when (err) {
                        is ToneEngineError.Offline ->
                            _mode.value = KeyboardMode.Error("No connection. Tap Back and try again when you have signal.")
                        is ToneEngineError.RateLimit ->
                            _mode.value = KeyboardMode.Error("Daily free limit reached (${err.usedToday}/${err.dailyLimit}). Open Tono to upgrade.")
                        else ->
                            _mode.value = KeyboardMode.Error(err.message ?: "Something went wrong. Tap Back and try again.")
                    }
                }
            )
        }
    }

    fun runRead() {
        val text = _draft.value.trim()
        if (text.isEmpty()) return

        coachTapTime = System.currentTimeMillis()
        TonoAnalytics.track(AnalyticsEvent.CoachRequested("read"))
        CrashReporter.addBreadcrumb("Read tapped")
        CrashReporter.setCustomKey(true, "network_in_flight")

        val req = AnalysisRequest(draft = text, mode = AnalysisMode.READ)
        val preview = MockToneAnalyzer.analyze(req)
        _mode.value = KeyboardMode.Results(preview, AnalysisMode.READ)
        val mockMs = (System.currentTimeMillis() - coachTapTime).toInt()
        TonoAnalytics.track(AnalyticsEvent.AnalysisShown(preview.riskLevel.value, mockMs, "mock"))

        viewModelScope.launch {
            runCatching {
                TonoBackend.analyze(text = text, mode = AnalysisMode.READ)
            }.fold(
                onSuccess = { result ->
                    _mode.value = KeyboardMode.Results(result, AnalysisMode.READ)
                    val llmMs = (System.currentTimeMillis() - coachTapTime).toInt()
                    TonoAnalytics.track(AnalyticsEvent.AnalysisShown(result.riskLevel.value, llmMs, "llm"))
                    CrashReporter.setCustomKey(false, "network_in_flight")
                },
                onFailure = { err ->
                    CrashReporter.setCustomKey(false, "network_in_flight")
                    _mode.value = KeyboardMode.Error(
                        if (err is ToneEngineError.Offline)
                            "No connection. Tap Back and try again when you have signal."
                        else err.message ?: "Something went wrong."
                    )
                }
            )
        }
    }

    // Called by the IME service when the user taps a rewrite chip
    fun onRewriteChosen(suggestion: RewriteSuggestion, analysis: ToneAnalysis): String {
        val recipientId = _selectedRecipient.value?.id
        StyleMemory.recordTap(suggestion.axis, recipientId)
        UserMemory.recordSession(analysis.flags, suggestion.axis.value)
        TonoBackend.logAxisWin(suggestion.axis.value, analysis.riskLevel.value)

        lastInsertedRewrite = suggestion.text

        val shownAxes = analysis.suggestions.map { it.axis.value }
        TonoAnalytics.track(AnalyticsEvent.RewriteInserted(suggestion.axis.value, shownAxes))
        val rejectedAxes = analysis.suggestions.filter { it.axis != suggestion.axis }.map { it.axis.value }
        if (rejectedAxes.isNotEmpty()) {
            TonoAnalytics.track(AnalyticsEvent.AxisRejected(shownAxes, suggestion.axis.value))
        }
        CrashReporter.addBreadcrumb("Rewrite inserted: ${suggestion.axis.value}")

        pendingOutcome?.let { outcome ->
            TonoAnalytics.track(AnalyticsEvent.ImprovementOutcome(
                riskLevel    = outcome.riskLevel,
                axisSelected = suggestion.axis.value,
                mode         = outcome.mode,
                msgLenBucket = outcome.msgLenBucket,
                rewriteUsed  = true,
                editAfter    = false,
            ))
            pendingOutcome = null
        }

        val count = SharedStore.getInt(SharedKeys.COACH_USE_COUNT) + 1
        SharedStore.putInt(SharedKeys.COACH_USE_COUNT, count)

        _mode.value = KeyboardMode.Keyboard
        return suggestion.text
    }

    fun goBack() {
        val current = _mode.value
        if (current is KeyboardMode.Results) {
            pendingOutcome?.let { outcome ->
                TonoAnalytics.track(AnalyticsEvent.ImprovementOutcome(
                    riskLevel    = outcome.riskLevel,
                    axisSelected = null,
                    mode         = outcome.mode,
                    msgLenBucket = outcome.msgLenBucket,
                    rewriteUsed  = false,
                    editAfter    = false,
                ))
                pendingOutcome = null
            }
        }
        _mode.value = KeyboardMode.Keyboard
    }

    private fun msgLenBucket(text: String): String = when {
        text.length < 50  -> "short"
        text.length < 200 -> "medium"
        else              -> "long"
    }
}
