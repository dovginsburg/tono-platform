import { redirect } from 'next/navigation';

export default function LandingPage() {
  // Per Ezra's brief: /app/ is a thin landing that always bounces
  // into the workspace. Auth gating happens at /app/app.
  redirect('/app/app');
}