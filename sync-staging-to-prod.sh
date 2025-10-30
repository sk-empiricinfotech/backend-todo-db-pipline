#!/bin/bash
set -e

# --------------------------------------------
# Supabase Staging → Production Sync Script
# With Auto Migration Repair for pull & push
# --------------------------------------------

# ✅ Check for required env vars
if [[ -z "$SUPABASE_ACCESS_TOKEN" || -z "$STAGING_REF" || -z "$PROD_REF" ]]; then
  echo "❌ Missing environment variables!"
  echo "Please export these before running:"
  echo "  export SUPABASE_ACCESS_TOKEN=your_token"
  echo "  export STAGING_REF=your_staging_ref"
  echo "  export PROD_REF=your_prod_ref"
  exit 1
fi

# ✅ Install Supabase CLI
echo "📦 Installing Supabase CLI..."
npm install supabase --save-dev > /dev/null

# ✅ Verify CLI
npx supabase --version

# ✅ Link to Staging
echo "🔗 Linking to Staging ($STAGING_REF)..."
npx supabase link --project-ref "$STAGING_REF"

# ✅ Pull schema from Staging
echo "⬇️ Pulling database schema from Staging..."

set +e
DB_PULL_OUTPUT=$(npx supabase db pull 2>&1)
PULL_EXIT_CODE=$?
set -e

if [[ $PULL_EXIT_CODE -ne 0 && "$DB_PULL_OUTPUT" == *"does not match local files in supabase/migrations directory"* ]]; then
  echo "⚠️ Migration mismatch detected (pull) — attempting automatic repair..."
  MIGRATION_ID=$(echo "$DB_PULL_OUTPUT" | grep -oE '[0-9]{14}' | tail -n 1)
  if [[ -n "$MIGRATION_ID" ]]; then
    echo "🛠️ Repairing migration history with ID: $MIGRATION_ID"
    npx supabase migration repair --status reverted "$MIGRATION_ID"
    echo "🔁 Retrying db pull..."
    npx supabase db pull
  else
    echo "❌ Could not detect migration ID automatically (pull)."
    echo "$DB_PULL_OUTPUT"
    exit 1
  fi
else
  echo "✅ DB pull completed successfully."
fi

# ✅ Download all functions from Staging
echo "⬇️ Downloading Edge Functions from Staging..."
FUNCTIONS=$(npx supabase functions list --output json | jq -r '.[].name')

if [[ -z "$FUNCTIONS" ]]; then
  echo "⚠️ No functions found in Staging project."
else
  for fn in $FUNCTIONS; do
    echo "📥 Downloading function: $fn ..."
    npx supabase functions download "$fn"
  done
  echo "✅ All functions downloaded successfully."
fi

# ✅ Link to Production
echo "🔗 Linking to Production ($PROD_REF)..."
npx supabase link --project-ref "$PROD_REF"

# ✅ Push schema to Production
echo "⬆️ Pushing schema to Production..."

set +e
DB_PUSH_OUTPUT=$(npx supabase db push 2>&1)
PUSH_EXIT_CODE=$?
set -e

if [[ $PUSH_EXIT_CODE -ne 0 && "$DB_PUSH_OUTPUT" == *"Remote migration versions not found in local migrations directory"* ]]; then
  echo "⚠️ Migration mismatch detected (push) — attempting automatic repair..."
  MIGRATION_ID=$(echo "$DB_PUSH_OUTPUT" | grep -oE '[0-9]{14}' | tail -n 1)
  if [[ -n "$MIGRATION_ID" ]]; then
    echo "🛠️ Repairing migration history with ID: $MIGRATION_ID"
    npx supabase migration repair --status reverted "$MIGRATION_ID"
    echo "🔁 Updating local migrations to match remote..."
    npx supabase db pull
    echo "🔁 Retrying db push..."
    npx supabase db push
  else
    echo "❌ Could not detect migration ID automatically (push)."
    echo "$DB_PUSH_OUTPUT"
    exit 1
  fi
else
  echo "✅ DB push completed successfully."
fi

# ✅ Deploy all functions to Production
echo "🚀 Deploying Edge Functions to Production..."
for fn in $FUNCTIONS; do
  echo "📤 Deploying function: $fn ..."
  npx supabase functions deploy "$fn"
done
echo "✅ All functions deployed successfully."

echo "🎉 Sync complete! Staging → Production is now in sync."
