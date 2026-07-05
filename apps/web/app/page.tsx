"use client";

import "@/lib/i18n";
import { useTranslation } from "react-i18next";
import { CoachForm } from "@/components/CoachForm";
import { CouponRedeem } from "@/components/CouponRedeem";
import { PasskeyAuth } from "@/components/PasskeyAuth";
import { SocialSignIn } from "@/components/SocialSignIn";
import { UpgradeButton } from "@/components/UpgradeButton";

export default function Home() {
  const { t } = useTranslation();
  return (
    <main>
      <div className="wordmark">
        <span className="wordmark-dot" aria-hidden="true" />
        <h1>{t("app.name")}</h1>
      </div>
      <p className="tagline">{t("app.tagline")}</p>
      <SocialSignIn />
      <PasskeyAuth />
      <UpgradeButton />
      <CouponRedeem />
      <CoachForm />
    </main>
  );
}
