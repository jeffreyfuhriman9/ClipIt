# ClipIt
ClipIt is a simple sports highlight extractor. When a video is begun in the ClipIt app, you simply hit the ClipIt button whenever a great play happens! After finishing recording, all the clips are generated and extracted afterwards into the highlight gallery along with the full recording.

## Supabase Setup

1. Create a project at [supabase.com](https://supabase.com).
2. In the Supabase dashboard, open **SQL Editor** and run the migration in `supabase/migrations/001_clipit_schema.sql`.
3. Copy `Secrets.plist.example` to `Secrets.plist` (if you don't already have one).
4. In Supabase, open **Project Settings → API** and copy:
   - **Project URL** → `SUPABASE_URL` in `Secrets.plist`
   - **anon public key** → `SUPABASE_ANON_KEY` in `Secrets.plist`
5. In Supabase, open **Authentication → URL Configuration** and add this redirect URL:
   - `clipit://login-callback`
6. In Supabase, open **Authentication → Providers** and enable **Anonymous sign-ins** (used for automatic cloud backup on first launch).
7. Build and run in Xcode. The app signs in anonymously on launch and uploads highlight clips after each session.

Cloud sync is optional — if `Secrets.plist` is missing or still has placeholder values, the app continues to work locally only.

