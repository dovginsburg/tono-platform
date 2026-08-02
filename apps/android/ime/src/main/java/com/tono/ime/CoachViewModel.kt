package com.tono.ime

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.tono.shared.analytics.AnalyticsEvent
import com.tono.shared.analytics.CrashReporter
import com.tono.shared.analytics.TonoAnalytics
import com.tono.shared.engine.MockToneAnalyzer
import com.tono.shared.flags.FeatureFlag
import com.tono.shared.flags.FeatureFlags
import com.tono.shared.intelligence.GeminiRewritePreferenceStore
import com.tono.shared.intelligence.OnDeviceFunnierResult
import com.tono.shared.intelligence.OnDeviceFunnierUseCase
import com.tono.shared.intelligence.OnDeviceRewriteEngine
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
import kotlinx.coroutines.Job
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

// The transient state of the explicit on-device Funnier gesture (Gemini Nano).
// Additive: it never replaces the backend Coach results, only augments them.
sealed class OnDeviceFunnierUiState {
    /** Affordance shown, nothing requested yet. */
    object Idle : OnDeviceFunnierUiState()
    /** A single on-device generation is in flight (cancellable). */
    object Running : OnDeviceFunnierUiState()
    /** A distinct on-device rewrite is ready for the user to insert. */
    data class Ready(val text: String) : OnDeviceFunnierUiState()
    /** Deterministic decline; [canDownload] true only when an explicit download could fix it. */
    data class Unavailable(val message: String, val canDownload: Boolean) : OnDeviceFunnierUiState()
}

class CoachViewModel : ViewModel() {

    private val _mode = MutableStateFlow<KeyboardMode>(KeyboardMode.Keyboard)
    val mode: StateFlow<KeyboardMode> = _mode

    private val _draft = MutableStateFlow("")
    val draft: StateFlow<String> = _draft

    private val _isPro = MutableStateFlow(SharedStore.getBoolean(SharedKeys.PRO_UNLOCKED))
    val isPro: StateFlow<Boolean> = _isPro

    // ── Google-intelligence: the explicit on-device Funnier gesture ──────────
    // The engine is INJECTED by the IME service (the only place ML Kit is
    // linked). Null here means the feature is unavailable — the affordance never
    // shows and no on-device code path can run. Default-off and fail-closed.
    private var onDeviceEngine: OnDeviceRewriteEngine? = null
    private val onDeviceFunnierUseCase = OnDeviceFunnierUseCase()
    private var onDeviceJob: Job? = null

    private val _onDeviceFunnier = MutableStateFlow<OnDeviceFunnierUiState>(OnDeviceFunnierUiState.Idle)
    val onDeviceFunnier: StateFlow<OnDeviceFunnierUiState> = _onDeviceFunnier

    /** Injected once by [TonoImeService]. Passing null disables the gesture. */
    fun attachOnDeviceEngine(engine: OnDeviceRewriteEngine?) {
        onDeviceEngine = engine
    }

    /**
     * Whether to OFFER the on-device Funnier affordance at all. Gated by the
     * remote/user kill switch (Pro-gated, default off) AND an attached engine.
     * The affordance's PRESENCE reveals nothing about the device; availability
     * is checked only on an explicit tap, so there is no prefetch here.
     */
    fun onDeviceFunnierOffered(): Boolean =
        onDeviceEngine != null && FeatureFlags.isEnabled(FeatureFlag.GEMINI_NANO_REWRITE)

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

        resetOnDeviceFunnier()
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
                            // 429 is the per-IP rate limit, NOT a free-tier daily
                            // cap (there is no free tier). Keep it honest.
                            _mode.value = KeyboardMode.Error("Too many requests right now. Please wait a minute and try again.")
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

    // ── On-device Funnier gesture (explicit only; no fan-out, no prefetch) ───

    /**
     * Run the explicit on-device Funnier gesture. Cancels any prior on-device
     * request first (so there is never more than one generation in flight), then
     * runs exactly one availability check + at most one generation via the pure
     * [OnDeviceFunnierUseCase]. The backend is never called from here.
     */
    fun requestOnDeviceFunnier() {
        val engine = onDeviceEngine ?: return
        if (!onDeviceFunnierOffered()) return
        onDeviceJob?.cancel()
        _onDeviceFunnier.value = OnDeviceFunnierUiState.Running
        CrashReporter.addBreadcrumb("On-device Funnier requested")
        onDeviceJob = viewModelScope.launch {
            val result = onDeviceFunnierUseCase.run(
                draft = _draft.value,
                engine = engine,
                remoteKillSwitchAllows = FeatureFlags.isEnabled(FeatureFlag.GEMINI_NANO_REWRITE),
                preference = GeminiRewritePreferenceStore.load(),
            )
            _onDeviceFunnier.value = when (result) {
                is OnDeviceFunnierResult.Rewrote ->
                    OnDeviceFunnierUiState.Ready(result.text)
                is OnDeviceFunnierResult.Unavailable ->
                    OnDeviceFunnierUiState.Unavailable(
                        message = OnDeviceFunnierUseCase.message(result.reason),
                        canDownload = OnDeviceFunnierUseCase.isDownloadable(result.reason),
                    )
            }
        }
    }

    /**
     * Explicitly download the on-device model, then re-run the gesture. Called
     * ONLY from the "Download model" affordance — never speculatively.
     */
    fun downloadOnDeviceModel() {
        val engine = onDeviceEngine ?: return
        if (!onDeviceFunnierOffered()) return
        onDeviceJob?.cancel()
        _onDeviceFunnier.value = OnDeviceFunnierUiState.Running
        onDeviceJob = viewModelScope.launch {
            engine.download() // explicit; suspends until the download resolves
            requestOnDeviceFunnier()
        }
    }

    /**
     * Consume a ready on-device rewrite for insertion. Returns the text and
     * resets the affordance, or null if nothing is ready. Insertion is the
     * user's explicit choice, exactly like tapping a backend rewrite chip.
     */
    fun takeOnDeviceRewrite(): String? {
        val state = _onDeviceFunnier.value
        if (state !is OnDeviceFunnierUiState.Ready) return null
        lastInsertedRewrite = state.text
        CrashReporter.addBreadcrumb("On-device Funnier inserted")
        val count = SharedStore.getInt(SharedKeys.COACH_USE_COUNT) + 1
        SharedStore.putInt(SharedKeys.COACH_USE_COUNT, count)
        _onDeviceFunnier.value = OnDeviceFunnierUiState.Idle
        return state.text
    }

    /** Dismiss/cancel the on-device gesture, returning to the plain affordance. */
    fun dismissOnDeviceFunnier() {
        onDeviceJob?.cancel()
        _onDeviceFunnier.value = OnDeviceFunnierUiState.Idle
    }

    private fun resetOnDeviceFunnier() {
        onDeviceJob?.cancel()
        onDeviceJob = null
        _onDeviceFunnier.value = OnDeviceFunnierUiState.Idle
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
        resetOnDeviceFunnier()
        _mode.value = KeyboardMode.Keyboard
    }

    private fun msgLenBucket(text: String): String = when {
        text.length < 50  -> "short"
        text.length < 200 -> "medium"
        else              -> "long"
    }
}
