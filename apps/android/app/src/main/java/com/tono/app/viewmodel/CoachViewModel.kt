package com.tono.app.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.tono.app.BuildConfig
import com.tono.app.net.TonoApiClient
import com.tono.app.net.TonoApiException
import com.tono.app.net.ToneAnalysis
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.util.Locale

sealed interface UiState {
    data object Idle : UiState
    data object Loading : UiState
    data class Result(val analysis: ToneAnalysis) : UiState
    data class Error(val message: String) : UiState
}

class CoachViewModel : ViewModel() {
    private val api = TonoApiClient(baseUrl = BuildConfig.TONO_API_URL)

    private val _state = MutableStateFlow<UiState>(UiState.Idle)
    val state: StateFlow<UiState> = _state

    fun coach(draft: String, mode: String = "coach") {
        if (draft.isBlank()) {
            _state.value = UiState.Error("Type a message first.")
            return
        }
        _state.value = UiState.Loading
        viewModelScope.launch {
            _state.value = try {
                val locale = Locale.getDefault().toLanguageTag()
                UiState.Result(api.analyzePublic(draft = draft, mode = mode, locale = locale))
            } catch (e: TonoApiException) {
                UiState.Error(e.message ?: "Something went wrong. Please try again.")
            } catch (e: Exception) {
                UiState.Error("Something went wrong. Please try again.")
            }
        }
    }
}
