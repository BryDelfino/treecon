#!/bin/sh
# Writes the app-local .env asset from Vercel project environment variables.
# Called by the Vercel Build Command before `flutter build web`.
printf 'SUPABASE_URL=%s\nSUPABASE_PUBLISHABLE_KEY=%s\nGOOGLE_WEB_CLIENT_ID=%s\nPYTHON_API_URL=%s\n' \
  "$SUPABASE_URL" "$SUPABASE_PUBLISHABLE_KEY" "$GOOGLE_WEB_CLIENT_ID" "$PYTHON_API_URL" > .env
