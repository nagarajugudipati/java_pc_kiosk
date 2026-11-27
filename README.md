# Lab Control System

A Java-based system designed to manage and control application usage in school/college computer labs. It provides real-time monitoring and blocking of unauthorized applications using a policy-driven architecture and CLI interface.

---

## Features Implemented

### CLI-Based Control System
- Interactive command-line interface for managing lab restrictions
- Supports adding blocked applications and websites
- Displays current system status

### Policy Management
- Uses JSON-based storage (`policy.json`) for persisting configurations
- Managed using Jackson library
- Stores:
  - Blocked Applications
  - Blocked Websites
  - System Mode (LAB / OPEN)

### Process Monitoring Engine
- Continuously monitors running system processes
- Detects blocked applications in real time
- Terminates matching processes using system commands

### Blocklist Approach
- Uses blocklist instead of whitelist for simplicity
- Easier to manage in dynamic lab environments

---

## Tech Stack

- Java 17+
- Maven
- Jackson (JSON processing)
- Windows system commands (tasklist, taskkill)

---

## CLI Commands

-block-app <app_name>
-block-site <domain>
-set-mode LAB
-status
-start
-exit


### Example Usage
-block-app calculator.exe
-block-app chrome.exe
-block-site facebook.com
-start


---

## Working Flow

1. User defines restrictions using CLI commands
2. Configuration is stored in `policy.json`
3. Process monitoring engine starts execution
4. System continuously checks running processes
5. If a blocked application is detected, it is terminated immediately

---

## Current Limitations

- Website blocking is not yet active (only stored in configuration)
- Relies on basic process listing (`tasklist`) for detection
- Requires administrator privileges for full functionality
- CLI-based system (no graphical interface)

---

## Future Enhancements

### Website Blocking System
- Implement hosts file-based blocking
- Activate `blockedSites` functionality

### Exam Mode
- Strict system lockdown
- Only approved applications allowed

### GUI Dashboard
- JavaFX-based interface for admin control
- Visual policy management system

### Improved Process Engine
- PID-based monitoring instead of text parsing
- Better accuracy and reliability
- Cross-platform support improvements

---

## How to Run

```powershell
mvn clean package
java -jar target/LabControlStudentAgent-1.0.0.jar --cli
# Start the background agent instead of the CLI
java -jar target/LabControlStudentAgent-1.0.0.jar
```

In the CLI, run `start` to log PC activity and enforce the policy. Run
`usage-start 576107 Test Student` to log new applications for that session.
The original no-argument command uses class `576107` and student `Unknown`.
The background agent logs PC activity. Student usage is started from the CLI.

## Supabase setup

1. Use the existing **intranet quiz** project (`kvwjpzowmqhwlehrbxwx`) under
   `umesh1424's Org`. It is shared with other applications. Run the
   [read-only deployment inventory](supabase/inspect-kiosk-deployment.sql)
   before any schema changes. Obtain explicit approval for each pending
   migration after reviewing its exact kiosk object changes.
2. In SQL Editor, run the [base kiosk migration](supabase/migrations/20261127000000_kiosk_logs.sql)
   if it has not already been applied. The [base schema check](supabase/verify-kiosk-schema.sql)
   describes permissions at this stage. Then run the
   [teacher reporting migration](supabase/migrations/20261127000100_teacher_reporting.sql)
   before starting the new Java build or dashboard. It backfills the report date on
   existing logs and briefly locks the kiosk tables. Schedule that step around normal kiosk usage.
   Apply the [class sessions migration](supabase/migrations/20261127000200_class_sessions.sql)
   after the reporting migration.
   Continue with [application policy visibility](supabase/migrations/20261127000300_app_policy_visibility.sql),
   [foreground duration](supabase/migrations/20261127000400_foreground_duration.sql), and
   [website policy](supabase/migrations/20261127000500_website_policy.sql), in that order.
   Run [the deployed schema checks](supabase/verify-deployed-kiosk.sql) after
   all three migrations. Expect five passing checks. These checks inspect privileges
   and RLS metadata. Complete the live sign-in and activity checks below as well.
3. In **Authentication → Users**, create a dedicated, confirmed email/password
   account for each kiosk. Copy its UUID. Keep the quiz app's sign-up settings
   as configured. The enrollment table controls access to the kiosk functions.
   In SQL Editor, enroll it with the kiosk's Windows `COMPUTERNAME` and the
   class codes it may submit. Use `'{}'` for an activity-only kiosk.

```sql
insert into kiosk_private.kiosks (user_id, pc_name, class_codes)
values ('REPLACE-WITH-AUTH-USER-UUID', 'LAB-PC-01', array['576107']);
```

4. Copy the project URL and the publishable API key from the project's
   dashboard. Configure the kiosk account locally using the settings below.

| Table | Columns |
| --- | --- |
| `usage_logs` | `id` UUID primary key, `class_code`, `app_name`, `process_name`, `student_log`, `student_name` (text), `timestamp` (bigint) |
| `pc_activity_logs` | `id` UUID primary key, `pc_name`, `app_name`, `process_name`, `action` (text, `OPENED` or `BLOCKED`), `timestamp` (bigint) |

Timestamps are Unix epoch milliseconds captured when the kiosk observes the
event. The reporting migration adds student and PC attribution where available,
nullable measured duration, the institution report date, server-managed timestamps,
and soft-delete markers. Authenticated kiosks submit through the batch RPC. Teacher
accounts have read-only access to assigned classes under row-level security.

### Configuration on Windows

Set these environment variables in the process that starts Java or use a local
Java properties file with the same names. The application reads environment
variables before properties values.

| Setting | Value |
| --- | --- |
| `SUPABASE_URL` | HTTPS project URL, such as `https://project-ref.supabase.co` |
| `SUPABASE_PUBLISHABLE_KEY` | Project API key beginning with `sb_publishable_` |
| `SUPABASE_KIOSK_EMAIL` | Dedicated kiosk account email |
| `SUPABASE_KIOSK_PASSWORD` | Dedicated kiosk account password |
| `SUPABASE_CONFIG_FILE` | Optional absolute path to the local properties file |

Use [the configuration template](.env.example) for either setup. For Task
Scheduler or a Windows service wrapper, put the values in
`%ProgramData%\LabControlStudentAgent\supabase.local.properties`. Restrict the
file and its directory with NTFS permissions to Administrators, SYSTEM, and the
account that runs the kiosk as needed. Give the kiosk account read access and
administrators write access. Use Java properties escaping for literal
backslashes and leading spaces. Restart the task or service after changes. Keep
the database password and privileged API keys out of this configuration and out
of the distribution.

The existing Windows installer registers a scheduled task at logon. To build
and install its package, run these commands from the repository root, using an
administrator shell for installation.

```powershell
.\scripts\build-windows-installer.ps1
.\scripts\install-windows-service.ps1
```

### Verification

1. Run `mvn test` for the monitor helpers and local HTTP retry and payload test.
2. In a test kiosk session, start both monitors. After one polling interval,
   open an allowed app such as Notepad, then a known blocked app such as Edge.
   Confirm that the policy terminates the blocked process and that SQL Editor
   shows an `OPENED` and a `BLOCKED` row in `pc_activity_logs`. Check
   `usage_logs` for the test class and student.
3. On a test kiosk, temporarily disconnect networking, repeat the process
   checks, reconnect, and open an allowed app again. Monitoring and blocking
   should continue. Logging resumes when Supabase is reachable. The queue
   holds 256 pending events in memory, sends up to 32 events per request,
   and retries transient failures up to twice.
   Events can be dropped during a prolonged outage, queue overflow, or shutdown.
4. Confirm that a publishable-key-only request cannot read either table and that
   a signed-in account without enrollment cannot submit events.

## Teacher dashboard

The dashboard is a separate Vite frontend distributed as `LabControl-Teacher-Dashboard`.
Run these commands from the standalone dashboard folder. Use Node
20.19+ or 22.12+ and copy its `.env.example` to `.env.local`. Set
`VITE_SUPABASE_URL` and the public `VITE_SUPABASE_PUBLISHABLE_KEY` for the same
Supabase project as the Java agent. `VITE_CACHE_RETENTION_DAYS` defaults to 30.

```powershell
npm ci
npm test
npm run dev
npm run build
```

The build writes static files to `dist` in the dashboard folder. Serve them over HTTPS
in production. Provision each teacher as a confirmed Supabase Auth user and run
the following in SQL Editor with administrative access. Replace the example UUID
and class code before running it.

```sql
insert into public.kiosk_classes (class_code) values ('576107') on conflict do nothing;
insert into public.teacher_profiles (user_id) values ('REPLACE-WITH-TEACHER-UUID') on conflict do nothing;
insert into public.teacher_class_assignments (user_id, class_code)
values ('REPLACE-WITH-TEACHER-UUID', '576107') on conflict do nothing;
```

For student-attributed reports, run `usage-start 576107 --student-id S-123 Student Name`
with the real institution-issued student ID, then `usage-stop` when the session
ends. The dashboard can show name-only usage detail, but the summary groups only
records with stable student IDs. The kiosk trusts the operator to enter the correct
ID. PC activity from the standalone background agent has no student or class
session and is visible to database administrators. When both monitors run in
the same CLI process, PC activity can use that session. Usage rows count opens
in the summary and attributed PC rows count blocks, avoiding duplicate open
counts across the two streams. The current kiosk detects launches and does not
measure elapsed app use. Reports show unknown duration as **Unavailable**.

Run [the optional cron setup](supabase/schedule-kiosk-reports.sql) after enabling
`pg_cron` in the Supabase project, or run
`select kiosk_private.refresh_daily_reports(5);` from an administrator job.
The job processes only changed class/date pairs in Asia/Kolkata. Use
`deleted_at` for corrections that remove a record. To correct the class or
date, tombstone the original row and insert a corrected row with a new ID.
Summary changes become available after the next aggregation run.

The dashboard starts with today's authorized records and loads cached dates on
later visits. Past dates default to summaries. **Load detailed activity** requests
the underlying rows for that date. **Sync Latest Activity** reads changes up to a
committed database watermark, using an `updated_at` and ID cursor. Cache writes
and cursor updates commit together. Search, class and activity filters, sorting,
charts, CSV exports, and browser print/PDF operate on cached records.

Initial access requires online validation. An already validated tab can show
cached data during a temporary outage for up to 15 minutes or until its access
token expires, whichever comes first. The dashboard checks class assignments
again on sync, date selection, and reconnect and removes revoked or expired cache
scopes. Logout clears the signed-in teacher’s local cache. Browser data is
accessible to someone with control of the same browser profile or device.
Use separate browser profiles on shared machines and treat exported files as
student records. IndexedDB contains report data and cursors. Auth session state
is stored separately for the current tab.

To verify a live setup, sign in as a teacher assigned to one class and compare
initial requests, manually synchronized requests, and local filter actions in
the browser Network panel. Change a permitted test row, refresh its daily
summary, and sync to confirm the change. Soft-delete the test row and repeat.
Revoke the teacher's test assignment and reconnect to confirm the scope is
purged. Verify a second teacher sees only their own class and cache.

### Managed class sessions

1. Add the dashboard's exact URL to Supabase Auth redirect URLs and configure
   password-reset email delivery. Provision teacher profiles as described above.
2. In the dashboard, expand **Class sessions and application control**, create
   a class, and start a session. The class picker uses the class name. Each
   session displays a separate join code valid for up to three hours.
3. Before students join, have an administrator enroll the managed computers
   for the class. Look up the class in `public.kiosk_classes`, then add its
   internal `class_code` to each registered device's `class_codes` array in
   `kiosk_private.kiosks`. The join code identifies an active session and
   does not grant access to unregistered computers.
4. Start the Java client with `--cli`. In the student's Windows account, run
   `join-class JOIN_CODE ROLL_NUMBER Student Name`. Run `leave-class` to
   end the local session. Student names and roll numbers are entered at join
   and remain operator-provided identities. No roster verification is enabled.
5. Use the dashboard to block or unblock a supported executable such as
   `notepad.exe`. Student overrides take precedence over device overrides,
   then class-wide rules. The Java client checks every 10 seconds and sends
   its policy acknowledgement on the next heartbeat. Start the interactive
   client in the student's account for managed enforcement. A background
   service can continue using its existing local baseline policy. Allowlist
   mode restricts the managed application inventory. Explicit unblock rules
   grant exceptions. Applications outside that inventory are unaffected.
6. End the class from the dashboard. Connected clients remove its restrictions
   at the next heartbeat. Offline clients stop applying the last class policy
   when its two-minute lease expires. The POSIX client can exercise class
   RPCs, while process enforcement is Windows-only.

### Centralized lab implementation status

| Phase | Status |
| --- | --- |
| Existing project analysis | Complete |
| Database, RLS, and Supabase Java migration | Implemented and tested locally |
| Class creation, join, presence, and end | Implemented. Local SQL tests cover enrollment and session boundaries |
| Remote application control | Blocklist and allowlist implemented for a fixed inventory. Windows physical testing pending |
| Website control and browser telemetry | Chrome/Edge extension and kiosk bridge implemented. Installed-browser testing pending |
| Teacher dashboard | Class controls, sign-in/reset flow, presence, and reporting implemented. Live Auth configuration pending |
| IndexedDB and incremental sync | Implemented and tested locally |
| Daily reporting | App and website event reporting implemented. Physical foreground timing verification pending |
| Deployment | Separate Supabase setup, historical import, browser administration, and physical multi-PC verification pending |

The managed Windows kiosk samples the foreground window every two seconds.
Switching away, leaving a class, or expiring a policy closes the tracked interval.
Durations are sampled estimates and split at Asia/Kolkata midnight. Background
processes can still be blocked according to policy. Their runtime is excluded
from foreground duration.

The kiosk saves each pending event under
`%LOCALAPPDATA%\LabControlStudentAgent\pending` in its Windows account profile.
Upload retries keep the original event ID. Acknowledged events are removed, and
invalid events are marked `.rejected` for an administrator to review. The
queue holds at most 4,096 files per account and Supabase project. Restrict access
to the Windows kiosk profile because queued records can include student data.

### Pair Chrome or Microsoft Edge on a test kiosk

1. Apply the website migration and rebuild the kiosk. In the kiosk's PowerShell
   session, generate a token and copy it to the clipboard without printing it.

   ```powershell
   $pairingBytes = New-Object byte[] 32
   $pairingRandom = [System.Security.Cryptography.RandomNumberGenerator]::Create()
   $pairingRandom.GetBytes($pairingBytes)
   $pairingRandom.Dispose()
   $env:KIOSK_BROWSER_TOKEN = [Convert]::ToBase64String($pairingBytes).TrimEnd('=').Replace('+','-').Replace('/','_')
   Set-Clipboard -Value $env:KIOSK_BROWSER_TOKEN
   ```

2. With the lab browser administrator's approval, open the browser's extensions
   page, enable Developer mode on the test device, and use **Load unpacked** to
   select this repository's `browser-extension` folder. Open the extension's
   options and paste the pairing token. Clear the clipboard afterward.
3. Launch the Java kiosk from the same PowerShell session and join a test
   class. In the teacher dashboard's **Website policy** section, block
   `example.org` for all computers. Give the kiosk and browser up to 45 seconds
   to refresh, then navigate to that domain. Repeat with **Unblock** and after
   ending the class. Verify the `example.org` activity rows with **Sync Latest Activity**.
4. Use institution-managed installation and pairing for deployment. A test
   browser profile where students can disable or remove the extension offers
   no enforcement guarantee. Keep the pairing token on its own kiosk.

Website rules apply to new top-level HTTP and HTTPS requests in paired Chrome and
Edge profiles and cover subdomains. An allowed subdomain can override a blocked
parent domain. The extension sends domain names and navigation outcomes only.
Already open pages can remain visible until the next navigation. Website
navigation duration is currently unavailable.

### Historical records

The retired writer used `classrooms/{class_code}/usageLogs/{id}` and
`pcActivityLogs/{id}` in source project `eschool-dev-4c6b4`. The Java agent
requires only Supabase at runtime. To import history, have the source owner
authorize a read-only Firestore identity for that project. Supply its short-lived
OAuth token through `KIOSK_HISTORY_READ_TOKEN` in the exporting shell. Keep the
export and CSVs local under an access-controlled directory. The repository
ignores `kiosk-history/`. The optional export utility reads both collections.

```powershell
New-Item -ItemType Directory -Force kiosk-history
.\scripts\export-kiosk-history.ps1 -SourceProject eschool-dev-4c6b4 -OutputFile kiosk-history/documents.json
Remove-Item Env:KIOSK_HISTORY_READ_TOKEN
.\scripts\convert-kiosk-history.ps1 -InputFile kiosk-history/documents.json -OutputDirectory kiosk-history
Push-Location kiosk-history
# Use the connection details from the Supabase project's Connect panel.
# Set PGHOST, PGPORT, PGDATABASE, PGUSER and PGSSLMODE=require.
# psql prompts for the database password when needed.
psql -f ../supabase/import-kiosk-history.sql
Pop-Location
```

An existing export can be used with the conversion command if it is a JSON array
of REST document objects with `name` and typed `fields`. The importer preserves
class paths and timestamps, writes both tables in a single transaction, and
generates stable row IDs so rerunning the same export skips the same records.
Compare the source export counts with the destination history before cutover.
The export reads the source database without deleting or updating its records.
   
