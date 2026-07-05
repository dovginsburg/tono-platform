"use client";

import { useState } from "react";
import { useTranslation } from "react-i18next";
import type { RewriteAxis, ToneAnalysis } from "@tono/shared";
import { TonoApiError } from "@tono/shared";
import { tonoApi } from "@/lib/api";
import { LanguageSwitcher } from "@/components/LanguageSwitcher";
import { ResultCard } from "@/components/ResultCard";

const PRESET_AXES: RewriteAxis[] = ["warmer", "clearer", "funnier", "safer"];

export function CoachForm() {
  const { t, i18n } = useTranslation();
  const [draft, setDraft] = useState("");
  const [mode, setMode] = useState<"coach" | "read">("coach");
  const [result, setResult] = useState<ToneAnalysis | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // All 4 presets on by default; a user can turn any subset off, and/or
  // add one custom axis (name + a plain-language instruction, since the
  // backend has no built-in idea what an arbitrary axis name should mean).
  const [enabledAxes, setEnabledAxes] = useState<Record<RewriteAxis, boolean>>({
    warmer: true,
    clearer: true,
    funnier: true,
    safer: true,
  });
  const [customAxisName, setCustomAxisName] = useState("");
  const [customAxisInstruction, setCustomAxisInstruction] = useState("");

  function toggleAxis(axis: RewriteAxis) {
    setEnabledAxes((prev) => ({ ...prev, [axis]: !prev[axis] }));
  }

  async function onCoach() {
    if (!draft.trim()) {
      setError(t("errors.textRequired"));
      return;
    }
    setLoading(true);
    setError(null);
    try {
      const axes = PRESET_AXES.filter((axis) => enabledAxes[axis]);
      const name = customAxisName.trim();
      const instruction = customAxisInstruction.trim();
      const analysis = await tonoApi.analyzePublic({
        draft,
        mode,
        locale: i18n.language,
        axes,
        custom_axes: name && instruction ? [{ name, instruction }] : [],
      });
      setResult(analysis);
    } catch (err) {
      setError(err instanceof TonoApiError ? err.message : t("errors.generic"));
    } finally {
      setLoading(false);
    }
  }

  return (
    <>
      <div className="row" style={{ justifyContent: "space-between" }}>
        <div className="row">
          <button
            className={mode === "coach" ? "primary" : "secondary"}
            onClick={() => setMode("coach")}
          >
            {t("coach.modes.coach")}
          </button>
          <button
            className={mode === "read" ? "primary" : "secondary"}
            onClick={() => setMode("read")}
          >
            {t("coach.modes.read")}
          </button>
        </div>
        <LanguageSwitcher />
      </div>

      <div style={{ marginTop: 16 }}>
        <textarea
          placeholder={t("coach.draftPlaceholder") ?? undefined}
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
        />
      </div>

      {mode === "coach" && (
        <div className="axis-settings">
          <span className="axis-settings-title">{t("coach.axisSettings.title")}</span>
          <div className="row" style={{ marginTop: 8 }}>
            {PRESET_AXES.map((axis) => (
              <button
                key={axis}
                type="button"
                className={`axis-chip ${enabledAxes[axis] ? "axis-chip-on" : ""}`}
                aria-pressed={enabledAxes[axis]}
                onClick={() => toggleAxis(axis)}
              >
                {t(`coach.axis.${axis}`)}
              </button>
            ))}
          </div>
          <div className="row" style={{ marginTop: 10 }}>
            <input
              type="text"
              placeholder={t("coach.axisSettings.customName") ?? undefined}
              value={customAxisName}
              onChange={(e) => setCustomAxisName(e.target.value)}
              style={{ flex: "1 1 160px" }}
            />
            <input
              type="text"
              placeholder={t("coach.axisSettings.customInstruction") ?? undefined}
              value={customAxisInstruction}
              onChange={(e) => setCustomAxisInstruction(e.target.value)}
              style={{ flex: "2 1 240px" }}
            />
          </div>
          <p className="muted-inline" style={{ marginTop: 6 }}>
            {t("coach.axisSettings.customHint")}
          </p>
        </div>
      )}

      <div className="row">
        <button className="primary" onClick={onCoach} disabled={loading}>
          {loading ? t("coach.analyzing") : t("coach.coachButton")}
        </button>
      </div>

      {error && <p className="error">{error}</p>}

      {result ? (
        <ResultCard result={result} />
      ) : (
        !error && <p className="empty-state">{t("coach.emptyState")}</p>
      )}
    </>
  );
}
