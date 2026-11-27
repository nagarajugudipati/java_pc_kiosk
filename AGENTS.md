# Shared Supabase project

Java PC Kiosk uses **intranet quiz** in **umesh1424's Org**, project reference
`kvwjpzowmqhwlehrbxwx`. Use this existing project exclusively.

Inspect the live schema using read-only SQL before proposing changes. Inventory
existing kiosk objects and reuse them. Keep new internal objects in
`kiosk_private` and use kiosk-specific names for required public API objects.
Show the exact objects affected and obtain explicit approval before applying
each migration. Leave other applications' objects, records, permissions,
and shared project, organization, and authentication settings intact.

Use authorized test accounts and synthetic records for live testing. Keep
passwords, personal access tokens, and privileged keys outside source control.
