#!/bin/bash
# Tono Backend - Railway Deploy Script
# Run from Mac mini: bash ~/Projects/apps/tono/backend/deploy.sh

set -e

echo "=== Tono Backend Deploy ==="

# Step 1: Login to Railway (opens browser)
echo ""
echo "Step 1: Logging into Railway..."
railway login
echo "Logged in"

# Step 2: Link to or create project
echo ""
echo "Step 2: Creating Railway project..."
cd ~/Projects/apps/tono/backend
railway init
echo "Project created"

# Step 3: Set environment variables
echo ""
echo "Step 3: Setting environment variables..."
railway variables set TONO_DB_PATH=/data/tono.db
railway variables set ANTHROPIC_MODEL=claude-haiku-4-5
echo "Set ANTHROPIC_API_KEY with: railway variables set ANTHROPIC_API_KEY=sk-ant-..."

# Step 4: Deploy
echo ""
echo "Step 4: Deploying..."
railway up
echo "Deployed!"

# Step 5: Get URL
echo ""
echo "Live URL:"
railway domain
echo ""
echo "=== Done ==="
