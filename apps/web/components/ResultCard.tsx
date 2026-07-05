"use client";

import { useState } from "react";
import { useTranslation } from "react-i18next";
import type { ToneAnalysis } from "@tono/shared";

export function ResultCard({ result }: { result: ToneAnalysis }) {
  const { t } = useTranslation();
  const riskKey = ["low", "medium", "high"].includes(result.risk_level)
    ? (result.risk_level as "low" | "medium" | "high")
    : "medium";

  return (
    <div className="card">
      <span className={`risk-badge risk-${riskKey}`}>
        {t(`coach.riskLevel.${riskKey}`)}
      </span>
      <p className="perception">{result.perception}</p>
      {result.subtext && <p className="subtext">{result.subtext}</p>}
      {result.risk_reason && <p className="risk-reason">{result.risk_reason}</p>}

      {result.suggestions.length > 0 && (
        <div className="suggestions">
          {result.suggestions.map((s, i) => (
            <SuggestionRow key={`${s.axis}-${i}`} axis={s.axis} text={s.text} rationale={s.rationale} />
          ))}
        </div>
      )}
    </div>
  );
}

function SuggestionRow({
  axis,
  text,
  rationale,
}: {
  axis: string;
  text: string;
  rationale?: string | null;
}) {
  const { t } = useTranslation();
  const [copied, setCopied] = useState(false);

  async function copy() {
    try {
      await navigator.clipboard.writeText(text);
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch {
      // clipboard API unavailable (e.g. insecure context) — no-op
    }
  }

  const axisKey = ["warmer", "clearer", "funnier", "safer"].includes(axis)
    ? axis
    : null;

  return (
    <div className="suggestion">
      <div className="suggestion-header">
        <span className="axis-label">{axisKey ? t(`coach.axis.${axisKey}`) : axis}</span>
        <button className="secondary" onClick={copy}>
          {copied ? t("coach.copied") : t("coach.copy")}
        </button>
      </div>
      <div>{text}</div>
      {rationale && <div className="rationale">{rationale}</div>}
    </div>
  );
}
