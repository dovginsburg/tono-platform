# Tono Slack App Setup Guide for Dov

**Goal:** Create the Tono Slack app in the Amazed Labs workspace and wire it up to the live backend.

**Current status:** `slack_configured: false` on the backend (health check confirms). The manifest and Railway CLI are ready.

---

## Step 1 — Create the Slack App from Manifest (2 min)

1. Go to https://api.slack.com/apps
2. Click **Create New App**
3. Choose **From an app manifest**
4. Select the **Amazed Labs** workspace
5. Paste the contents of `~/Projects/apps/tono/backend/slack_manifest.yaml` (already updated to use `https://api.tonoit.com`)
6. Click **Next**, then **Create**
7. On the app settings page, note down:
   - **Client ID** (under *Basic Information* → *App Credentials*)
   - **Client Secret** (same section)
   - **Signing Secret** (same section)

---

## Step 2 — Set Railway Environment Variables (1 min)

Railway CLI is already installed and logged in as you. Run these commands from the `~/Projects/apps/tono/backend` directory:

```bash
cd ~/Projects/apps/tono/backend
railway project tono-backend
railway variables --set SLACK_CLIENT_ID="<your-client-id>"
railway variables --set SLACK_CLIENT_SECRET="<your-client-secret>"
railway variables --set SLACK_SIGNING_SECRET="<your-signing-secret>"
```

After setting, redeploy:

```bash
railway up
```

Or trigger a redeploy from the Railway dashboard.

---

## Step 3 — Install the App to the Workspace (30 sec)

1. In the Slack app settings, go to **OAuth & Permissions**
2. Click **Install to Workspace**
3. Authorize the `commands` and `chat:write` scopes
4. Copy the **Bot User OAuth Token** (`xoxb-...`) — you’ll need it for the next step

---

## Step 4 — Create Slack Channels (1 min)

You can create channels manually in Slack, or use the bot token from Step 3 to create them via API:

**Option A — Manual:**
- Create `#tono`
- Create `#parentscript`

**Option B — API (run these after you have the `xoxb-...` token):**

```bash
# Create #tono
curl -s -X POST https://slack.com/api/conversations.create \
  -H "Authorization: Bearer <xoxb-token>" \
  -H "Content-Type: application/json" \
  -d '{"name": "tono", "is_private": false}'

# Create #parentscript
curl -s -X POST https://slack.com/api/conversations.create \
  -H "Authorization: Bearer <xoxb-token>" \
  -H "Content-Type: application/json" \
  -d '{"name": "parentscript", "is_private": false}'
```

Then invite the Tono bot to both channels.

---

## Step 5 — Verify (10 sec)

Run a slash command in any channel:

```
/tono This is a test message
```

You should see an ephemeral card with tone risk + rewrite suggestions.

Check backend health to confirm Slack is wired:

```bash
curl -s https://api.tonoit.com/health | python -m json.tool
```

Look for `"slack_configured": true`.

---

## Files Referenced

| File | Purpose |
|------|---------|
| `~/Projects/apps/tono/backend/slack_manifest.yaml` | App manifest (already updated to `api.tonoit.com`) |
| `~/Projects/apps/tono/backend/slack.py` | Backend handlers for `/slack/command`, `/slack/oauth`, `/slack/interaction` |
| `~/Projects/apps/tono/backend/server.py` | Health check endpoint (`/health`) |

---

## What Gary Found

- ✅ **Manifest is correct and ready** — all URLs point to `https://api.tonoit.com`
- ✅ **Railway CLI is installed** and logged in as Dov (`dov.ginsburg@gmail.com`)
- ✅ **Railway project `tono-backend` exists** and is running
- ⚠️ **Slack env vars are NOT set** in Railway (confirmed via `railway variables`)
- ⚠️ **No Slack bot token** was found in `~/.hermes/.env` or environment, so Gary cannot create channels via API
- ⚠️ **Dov must perform Steps 1–4 manually** (create app, copy creds, set Railway vars, install to workspace)
