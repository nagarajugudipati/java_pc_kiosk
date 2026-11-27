# Java PC Kiosk handover

## Deployment target

The Java client and teacher dashboard use the existing shared **intranet quiz**
Supabase project in **umesh1424's Org**. Its project reference is
`kvwjpzowmqhwlehrbxwx`. Use the local configuration described in [README](README.md).

## Migration review

Run [the read-only inventory](supabase/inspect-kiosk-deployment.sql) against the
shared database. SQL Editor execution may leave no CLI migration history.
Check deployed definitions and grants before applying or repeating any migration.

| Migration | Kiosk-specific changes |
| --- | --- |
| `20261127000300` | Change the `app_mode` default on `kiosk_private.class_sessions` to `ALLOWLIST` for future sessions. Create owner-scoped `public.kiosk_app_rules(uuid)` and grant authenticated execution. |
| `20261127000400` | Replace `public.record_usage_log(jsonb)` with a duration-aware definition. Preserve the signature and existing execution grants. |
| `20261127000500` | Create `kiosk_private.website_rules` with RLS and a unique constraint. Create authenticated RPCs `public.kiosk_set_website_rule(uuid,uuid,text,boolean)`, `public.kiosk_website_rules(uuid)`, and `public.kiosk_device_website_rules(uuid)`. |

The website setter increments the kiosk session policy version and upserts a
website rule when called by the class owner. Applying these files requires
explicit approval. The migrations require no project settings changes.

## Verification

Earlier live checks covered teacher sign-in, class creation, kiosk join,
heartbeat, activity storage, and a real Notepad launch. Local tests cover
migrations, access controls, cache synchronization, and offline replay.
After approval and deployment, repeat the live tests with synthetic records,
including managed Chrome and Edge block/unblock, foreground duration,
end-of-class recovery, and daily and historical reports.
