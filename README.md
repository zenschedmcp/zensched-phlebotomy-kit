# ZenSched Mobile-Phlebotomy Reference Kit

A copy-pasteable setup for a small mobile phlebotomy company (1–10 phlebotomists; standing homebound draws, one-off house calls, cash-pay clinics, trial sites, employer panels) that wants an AI assistant to run draw scheduling, GPS-verified arrival at the door, a Draw Record (tube count, cooler temp, outcome), local patient records, payroll hours, and lab invoicing by patient code. ZenSched handles the live schedule, the phone app, GPS check-ins, the Draw Record form, and timesheets. A small local database on your computer holds your labs, patients, addresses, standing schedule, draw log, and invoices.

**You do not need to know how to program or write SQL to use this.** You type plain English to your AI assistant ("schedule next week", "add a patient", "anything I should worry about?", "invoice Riverside", "run payroll") and the AI does the work using two tools you set up once. Setup takes about 15 minutes and is the only technical part.

If you *are* a developer, skip to [For developers](#for-developers).

## HIPAA and what this kit is not

**What this kit is:** a way for a small mobile-draw company to get GPS-verified, timestamped records of every house call, keep patient information on the company's own computer, and turn those records into payroll hours and lab invoices with an AI assistant doing the clerical work.

**What it is not:**

- **ZenSched is not a HIPAA business associate and does not sign a BAA.** This kit is built so that protected health information never reaches ZenSched. Patient name, date of birth, MRN, phone, fasting notes, special-draw notes (hard stick, port, mastectomy side), and door codes are stored **only** in the local SQLite database on your computer. ZenSched receives, per address, a short de-identified label (`Draw 12 - Maple`), the street address for the GPS pin, and the Draw Record the phlebotomist fills in: tube count, cooler temperature, a fasting Yes/No/Not-required flag, outcome, complications, and optional photos of tube labels. No patient name, no test names, no MRN, no diagnosis. `SKILL.md` makes this a hard rule the AI will refuse to break. You are still responsible for your own HIPAA obligations (the local database, your email, your phlebotomists' phones); this kit narrows what a third party sees, it does not make you compliant by itself. If you need a BAA, this kit is not for you yet.
- **This is not a LIMS.** There is no accessioning, no test menu, no specimen chain-of-custody beyond a tube count and a cooler temperature, no result reporting, and no interface to an analyzer or a reference-lab system. Order what to draw, and report results, somewhere else. The kit schedules the visit and proves someone arrived and collected tubes.
- **This is not an EHR and not a certified EVV vendor.** It does not submit to any state aggregator and does not store a problem list or medication list.

If a BAA, a LIMS, or Medicaid EVV is a deal-breaker, stop here. If you run private-pay / cash-clinic / trial / employer draws and want proof-of-visit the lab will accept, read on.

## What lives where

**ZenSched (source of truth for what happened, when, and where):**

- Locations (draw addresses with GPS coordinates; the check-in radius is a **policy** setting, not a per-house setting)
- Workers (phlebotomists with the mobile app)
- Events (one "Draws" job per address, renewed every 60 days)
- Shifts (each draw window, typically 30 minutes, with push notifications)
- GPS punches (check-in/check-out with distance-from-the-door verification)
- The Draw Record form (tube count, cooler temp, fasting, outcome, complications, optional tube-label photos) and every submission
- Timesheets (verified hours worked, exportable for payroll)

**Local SQLite database (`phleb-ops.db`, on your computer):**

- Clients: the lab / trial / employer / concierge / cash-pay clinic that is billed, and their per-draw rate
- Patients: name, date of birth, MRN, phone, fasting notes, special-draw notes — **never leave your computer**. Each patient gets a `patient_code` (`P-0001`) used on invoices
- Addresses, including access notes (door code, gate, parking) — **never leave your computer**. `zensched_label` is the only string sent to ZenSched
- Phlebotomists: contact, hourly pay rate
- Optional standing schedule (weekday mask) for homebound patients
- Booked and completed draws with hours, flat bill amount, tube count, outcome; payroll flags; invoices to the **lab**
- Your settings (timezone, default per-draw bill rate, default hourly pay, default 30-minute window, invoice prefix, Draw Record form id)

**Never duplicated:** the live schedule, punches, timesheets, and tube-label photos stay in ZenSched. The local database only stores *references* to them plus a per-draw summary so you can answer "how many Unable this week" without paying to re-read records.

### Privacy note

Everything that could identify a patient's health condition, and every access code, lives only in the local database: `patients.patient_name`, `dob`, `mrn`, `phone`, `fasting_notes`, `special_draw_notes`, and `addresses.access_notes`. `SKILL.md` forbids the AI from putting any of them into any ZenSched field, including location names, event titles, notes, and cancellation reasons (phlebotomists see those). Give fasting instructions and special-draw notes to your phlebotomists yourself. ZenSched only ever sees the de-identified label, the street address, and the GPS pin. The Draw Record form itself tells phlebotomists not to write patient names or test names.

## How it works day to day

Your AI assistant has two sets of tools:

1. **ZenSched tools** (`location_create`, `shift_create`, `form_submissions`, `shift_list`, `timesheet_export`, ...) that talk to ZenSched over the internet.
2. **A SQLite tool** (`sqlite_query`, `sqlite_execute`) that reads and writes `phleb-ops.db` on your computer.

When you say "schedule next week," the AI expands standing Mon/Wed/Fri slots plus any booked one-offs for the next 7 days, assigns each draw to the preferred phlebotomist, creates one shift per draw on ZenSched, and tells you what it did. Your phlebotomist sees the window in the app, checks in at the door (GPS-verified), draws, fills in the Draw Record (Submit — there is no signature step), and checks out. Later you say "record this week's draws" and the AI pulls the completed shifts, the verified times, and the records, saves a summary locally, and leads with any Unable or complication. "Run payroll" totals verified hours per phlebotomist; "invoice Riverside" produces a lab invoice whose line items are **patient codes**, never names. You never run SQL yourself. `SKILL.md` in this repo is the instruction sheet that teaches the AI how to do all of this; you paste it into your AI tool once.

## Setup

### 0. What you need

- **An AI tool that supports MCP.** These instructions use Claude Desktop (Windows or Mac). Cursor works too.
- **Node.js 20 or newer.** The SQLite tool runs on it. Download the LTS installer from [nodejs.org](https://nodejs.org/) and run it with the defaults. This is the only software install.
- You do **not** need the `sqlite3` command-line program, Python, or Git.

### 1. Make a folder for your data

Create a folder where the database will live and write down its full path. Examples:

- Windows: `C:\Users\YourName\phleb-ops`
- Mac: `/Users/yourname/phleb-ops`

The database file will be created automatically inside this folder the first time the AI uses it. This folder will contain patient health information; treat it like a filing cabinet (encrypted disk, backed up, not in a shared Dropbox folder).

### 2. Add both tools to your AI's config file

Open the MCP configuration file for your AI tool:

- **Claude Desktop, Windows:** `%APPDATA%\Claude\claude_desktop_config.json` (paste that into the File Explorer address bar)
- **Claude Desktop, Mac:** `~/Library/Application Support/Claude/claude_desktop_config.json` (in Claude Desktop: Settings → Developer → Edit Config)
- **Cursor:** Settings → MCP → Add new global MCP server

Paste in the contents of `mcp.json.example` from this repo, then change one line, the `SQLITE_PATH`, to point at your folder from step 1 plus `\phleb-ops.db` (Windows) or `/phleb-ops.db` (Mac):

```json
{
  "mcpServers": {
    "zensched": {
      "url": "https://mcp.zensched.com/mcp",
      "headers": { "Authorization": "Bearer zsc_your_key_here" }
    },
    "phleb-ops-db": {
      "command": "npx",
      "args": ["-y", "easy-sqlite-mcp"],
      "env": { "SQLITE_PATH": "/Users/yourname/phleb-ops/phleb-ops.db" }
    }
  }
}
```

**Windows path gotcha:** inside a JSON file every backslash must be doubled. Write `"C:\\Users\\YourName\\phleb-ops\\phleb-ops.db"`, not `"C:\Users\..."`. A single backslash will silently break the config.

**Leave `zsc_your_key_here` exactly as it is for now.** You do not have a key yet. The ZenSched tools that create your account work without one, and you will fill this in during step 3.

Save the file and **fully quit and reopen** your AI tool (on Mac, Cmd-Q; on Windows, right-click the tray icon → Quit). It only reads this file on startup.

### 3. Create your ZenSched account

In a new chat, type:

> Call `zensched_guide`, then call `account_create` with org_name "My Mobile Draws" (use my real business name if I told you one). Show me the `zsc_` key it returns.

Copy the `zsc_` key. Go back to the config file from step 2, replace `zsc_your_key_here` with your real key, save, and fully quit and reopen the AI tool again.

Some clients can adopt the key mid-session with `account_use_key`; you can ask the AI to try that to keep going immediately, but still update the config file so the key survives restarts. Keep the key private; it is the password to your account.

### 4. Create the database tables

Open `schema.sql` from this repo in any text editor, copy the whole thing, and paste it into the chat with this message in front of it:

> Create these tables in my phleb-ops database. Run each statement one at a time using the SQLite tool, then list the tables to confirm.

The AI will run 49 statements and confirm the tables exist. The `phleb-ops.db` file now exists in your folder with default settings ($55 per draw billed, $22/h pay, 30-minute windows) you can change.

If you happen to have the `sqlite3` command-line tool, `sqlite3 phleb-ops.db < schema.sql` does the same thing, but it is not required.

### 5. Teach the AI the workflow

Paste the contents of `SKILL.md` into your AI tool as standing instructions. In Claude Desktop, create a Project and put it in the project instructions; in Cursor, save it as a rule. Then tell it your basics once:

> We're River Mobile Draws, Central time. We bill $55 a draw and pay $22 an hour unless I say otherwise. Save that in settings and set up the Draw Record form.

It writes those to the `settings` table, creates the Draw Record form on ZenSched (free), and saves the form id so every address's draws get it automatically.

**Check-in radius.** The default is 75 m around the geocoded pin. ZenSched enforces the radius through the account's **policy**, not per house, and with geofencing on it raises anything under 100 m to about 91 m (300 ft), so 75 behaves as roughly a house-and-driveway circle. For a large rural lot or a pin that lands on the road, ask the AI to "set the check-in radius to 200 m" (`policy_update`) or to move the pin onto the building (`location_update`, free). Never "widen the radius on that location" — that field is informational only. `remote_checkin` turns GPS verification off for every address on the policy and should be a last resort.

**Forgotten check-outs.** Ask the AI to "remind phlebotomists to check out 15 minutes after the shift ends" (`checkout_reminder_min_after`). If you would rather they fix a missed check-out in the app, ask for "let phlebotomists edit their times" (`timesheet_edit: "times_only"`); it is off by default.

### 6. Funding (only when asked)

The first 200 ZenSched tool calls per day are free. Some things are metered: creating a location (geocoding, $0.03), inviting a phlebotomist ($0.25), each GPS-verified check-in or check-out ($0.10), reading a Draw Record ($0.05, or **$0.15 when it has tube-label photos**; each record is billed once, ever), and a processed timesheet with breaks and overtime ($0.10; the plain hours export is free). When a metered call happens without funds, the AI will get a `payment_required` response and tell you how to add the $5 activation deposit, which is credited to your balance. You will not be charged without seeing this first.

For a standing patient on three draws a week that is $0.60 in GPS verification plus $0.15–$0.45 in record reads per week, about $3–$5 a month per standing patient; the AI states the cost before it spends.

## Using it

Everything after setup is plain English. Examples:

- "Add a cash-pay clinic: Riverside Cash Clinic, billing@riverside.example, $55 a draw, net 15."
- "Add a standing patient: Eleanor Briggs, 412 Maple Street, Austin TX 78704. DOB 1948-02-11, MRN RIV-4412. 12-hour fast. Hard stick, left antecubital preferred. Door code 1357. Mon/Wed/Fri 8:00, 30 minutes, give her to Dana."
- "Add a one-off Thursday 10 to 11 at 88 Cedar Avenue for patient code we'll assign — cash clinic, same rates."
- "Invite Dana Okonkwo, dana@example.com, $24 an hour."
- "Schedule next week."
- "Record this week's draws."
- "Anything I should worry about?" (open complications / Unable)
- "Invoice Riverside — codes only."
- "Run payroll for last week."
- "Who still owes me money?"

See `QUICKSTART.md` for the first-week walkthrough and `example-workflow.md` for exactly which tools the AI calls behind each of these.

### What "invoice" means here

"Draft an invoice" records the invoice in your database (number, date, due date, draw count, amount, line items) and the AI writes out a plain-text invoice you can paste into an email to the **lab or clinic**. Each line is date, **patient code**, outcome, tube count, amount. It does **not** generate a PDF, email it for you, or collect payment. Invoices never mention patient names, MRNs, diagnoses, or test menus. When the lab pays, tell the AI ("Riverside paid INV-2026-0001") and it marks it paid.

### What "payroll" means here

"Run payroll" totals GPS-verified hours per phlebotomist from the local draw log, cross-checks them against ZenSched's free hours export, and writes a per-phlebotomist summary (hours × pay rate = gross) you hand to whoever runs your payroll. Labs are billed a **flat per-draw fee**; phlebotomists are paid **hourly** from the punches. The kit does not calculate taxes or pay anyone.

## Mobile app for phlebotomists

- **Android:** [Google Play](https://play.google.com/store/apps/details?id=com.zensched.app)
- **iOS:** [TestFlight](https://testflight.apple.com/join/Wp51m5Yq)

When you invite a phlebotomist, they get an email, install the app, and can immediately see their windows, check in and out with GPS verification, and fill in the Draw Record. There is **no signature field** — they tap Submit when the record is complete.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| AI says it has no ZenSched tools | Config file not saved, or the app was not fully restarted | Check the JSON is valid (paste it into [jsonlint.com](https://jsonlint.com)), then quit and reopen the app |
| AI says it has no SQLite / `phleb-ops-db` tools | Node.js not installed, or bad `SQLITE_PATH` | Install Node.js LTS; on Windows check every backslash is doubled |
| `SQLITE_PATH` points nowhere / "unable to open database" | Folder from step 1 does not exist | Create the folder; the file is created automatically but the folder is not |
| ZenSched tools return an auth error | Key still says `zsc_your_key_here`, or was pasted with a space | Re-paste the key, restart |
| `payment_required` | Metered call with no balance | Follow the instructions in the response; $5 deposit |
| AI creates shifts at the wrong hour | Timezone not set | "Set my timezone offset to -05:00 in settings" (use your own offset) |
| Shift creation fails for dates a couple of months out | The address's 60-day ZenSched event has expired | Say "renew the events"; the AI runs the roll-over in `SKILL.md` and retries |
| Phlebotomist's check-in not GPS-verified | Pin is at the road, parked far away, or a campus | "Set the check-in radius to 200 m" (`policy_update`), or "move the pin onto the building" (`location_update`, free), or `location_refine` ($0.10) |
| Phlebotomist forgot to check out | Shift still `checked_in` | Tell the AI the real end time; ask for a 15-minute check-out reminder, or enable time edits |
| Phlebotomist does not see the Draw Record | Form not assigned to that address's event | "Attach the Draw Record to the Maple event" (`form_assign`) |
| "Unable reason" shows even when the draw succeeded | Conditional fields are web-only on ZenSched | Harmless; leave it blank |
| Record read cost more than $0.05 | Tube-label photos trip the **media** meter ($0.15) | Working as designed; the AI should have warned you |
| Invoice to the lab has a patient name | Agent mistake | Tell it to rewrite using `patient_code` only |
| AI refuses to put an MRN or test name in ZenSched | Working as intended | Give it to the phlebotomist directly |
| Payroll hours differ from ZenSched | Phlebotomist punched far off schedule, or hours were entered by hand | The AI shows both; tell it which to keep |
| AI asks you to run SQL yourself | It does not have `SKILL.md` loaded | Re-paste `SKILL.md` as project instructions |

If something is confusing or broken in ZenSched itself, ask the AI to call `feedback_submit` with a description. It is free, needs no account, and a human reads every submission.

## For developers

**Architecture.** Two MCP servers, no application code. The agent is the integration layer; `SKILL.md` is the spec it follows. ZenSched is authoritative for operations (schedule, punches, forms, timesheets); SQLite is authoritative for patients (including all PHI), labs, roster, recurrence, payroll flags, and billing; each side stores only the other's **integer** IDs, plus a per-draw summary cached locally because submission reads are metered. The PHI boundary is enforced by data placement (PHI columns exist only locally) and by `SKILL.md` rule 1; there is no technical control stopping a misbehaving agent, so review the rule if you swap models.

**Data model decisions.**

- One ZenSched **location** per address, permanent, stored on `addresses.zensched_location_id`. Created with `location_create(name=<zensched_label>, street_address=..., checkin_radius_m=75, idempotency_key=...)`. `addresses.zensched_label` is the only name that crosses to ZenSched. `checkin_radius_m` on `location_create` is informational; the enforced radius is `policy_update(0, '{"checkin_radius_m": N}')`, and with geofencing on the platform raises values under 100 m to 300 ft.
- **Events are capped at 60 days by ZenSched** (same roll as the pet-care kit). Each address holds its *current* event in `addresses.zensched_event_id` and its last covered date in `addresses.event_valid_until`. The agent creates a new event (`event_create(location_id, title="Draws - <label>", start_date, end_date=start+59 days, idempotency_key="event-address-{address_id}-{YYYYMMDD}")`) whenever a shift date is later than `event_valid_until`, calls `form_assign(form_id, event_id=...)` on it, and updates the row. `draws_due_this_week` exposes `event_needs_roll` per row and the `event_needs_roll` view lists addresses due for renewal within 14 days. Shifts already created on the old event remain valid. When recording a completed draw whose `event_id` no longer matches an address, the agent falls back to `event_get(event_id).location_id` against `addresses.zensched_location_id`.
- **Recurrence is per weekday; one-offs are rows.** `draw_schedule.weekdays` is a 7-character `0/1` mask, Monday first, `CHECK`-constrained; `start_time` is `HH:MM`; `duration_minutes` is 15–240. `draws_due_this_week` UNIONs the recursive-CTE expansion (minus dates already in `draws` for that `schedule_id`) with one-off `draws` (`schedule_id IS NULL`, status `scheduled` or `checked_in`) in the next 7 local days. Day-scoped views use `date('now', 'localtime')` because the SQLite MCP server runs on the owner's computer.
- **Continuity.** `draw_schedule.preferred_worker_id` is a ZenSched worker id. The view's `worker_id` is `COALESCE(preferred_worker_id, <zensched_worker_id of the most recent draw on this schedule row>)`, with `unassigned = 1` when both are NULL. There is no global default phlebotomist; the agent asks rather than guesses.
- **Labs pay per draw; phlebotomists are paid hourly.** `fill_draw_derived` snapshots `bill_rate` from the client (else settings), `pay_rate` from the phleb (else settings), `hours` from punches (else the scheduled window), and sets `bill_amount = bill_rate` (flat). Rate changes never rewrite history. Unable draws still bill the flat fee unless the owner zeros `bill_amount`.
- `draws.zensched_shift_id` and `phlebs.zensched_worker_id` are `UNIQUE` integers. `draws.report_dc_id` holds the form `submission_id`. Outcome / fasting / complications are `CHECK`-constrained to the form's option keys.
- `patients.patient_code` is auto-assigned `P-0001` by trigger. `invoices.invoice_number` is `{prefix}-{YYYY}-{0001}`. Invoice `line_items` carry `patient_code`, never `patient_name`. `draws_to_invoice` and `invoices_outstanding` omit names.
- `clients.client_type` (`lab | trial | employer | concierge | cash`) is `CHECK`-constrained.
- `open_complications` is `complications <> 'none'` or `draw_outcome = 'unable'` in the last 14 local days, Unable first.
- `PRAGMA foreign_keys = ON` is in `schema.sql` and `SKILL.md` tells the agent to run it per session; SQLite does not persist it. Deleting a patient cascades to addresses, schedule rows, and draws; deleting a phleb sets `draws.phleb_id` NULL.

**Draw Record form.** Created once with `form_create(title, fields_json, idempotency_key="form-draw-record")`; the exact `fields_json` is in `SKILL.md` and was validated against ZenSched's `_validate_fields`. Every field carries an explicit `identifier` so submission `data` keys are stable: `tube_count`, `cooler_temp_c`, `fasting`, `draw_outcome`, `unable_reason`, `complications`, `complication_notes`, `tube_labels`. Option keys: `yes` / `no` / `not_required`; `successful` / `partial` / `unable`; `none` / `hematoma` / `faint` / `other`. `unable_reason` `show_if` `draw_outcome` equals `unable`; `complication_notes` `show_if` `complications` not_equals `none`. **No signature field** — a signature field would replace Submit with a signature pad. Optional `photo` `tube_labels` `max_images` 2; any photo trips the media meter. Attaching is `form_assign(form_id, event_id=...)`.

**Idempotency keys.** Deterministic, derived from local IDs:

- location: `loc-address-{address_id}`
- event: `event-address-{address_id}-{YYYYMMDD window start}`
- standing shift: `shift-address-{address_id}-{YYYYMMDD}-{HHMM}`
- one-off shift: `shift-draw-{draw_id}`
- cancel: `cancel-{shift_id}`
- worker: `worker-{email}`
- form: `form-draw-record`; assignment: `assign-draw-record-{event_id}`

ZenSched caches idempotent responses for 24 hours.

**Timestamps.** `shift_create` takes `start` and `end` in ISO 8601 with an explicit offset. Always use the business's local offset from `settings.timezone_offset` (e.g. `2026-09-07T08:00:00-05:00`), never `Z`. The view builds these strings so the agent does not have to.

**Metered reads.** `form_submissions` and `form_export` bill $0.05 per submission read ($0.15 with photo media), once per submission ever. A form with no photos bills basic even if it has selects and numbers. `shift_list`, `shift_status`, `event_get`, and `timesheet_export(mode="hours"|"raw")` are free; `mode="processed"` is $0.10.

**SQLite MCP server.** `mcp.json.example` uses [`easy-sqlite-mcp`](https://github.com/chenkumi/easy-sqlite-mcp) (Node, `better-sqlite3`, `SQLITE_PATH` env var). Its `sqlite_execute` calls `prepare()`, so it accepts **one statement per call**; `schema.sql` is written so every statement stands alone and is idempotent.

**Schema test.** The schema was verified by splitting the file into its 49 statements with `sqlite3.complete_statement` and executing each individually (as the MCP server does) twice for idempotency (seed rows not duplicated), then exercising: all 8 tables, 7 views, and 8 triggers; every view on an empty database; the recursive-CTE UNION view against a Mon/Wed/Fri standing mask (3 rows on the right weekdays) plus a one-off in-window; `event_needs_roll` flipping after `event_valid_until`; exclusion of already-recorded standing dates; overnight `hours` across midnight; `UNIQUE` on `zensched_shift_id` and `zensched_worker_id`; every `CHECK` (client type, weekday mask, start time, duration, status, outcome, fasting, complications); foreign keys (cascade patient → address/draws, set-null phleb, restrict client); the `updated_at`, `fill_patient_code`, `fill_draw_derived` (hours, flat bill, rate fallbacks), and invoice-numbering triggers; `draws_to_invoice` omitting patient names; `payroll_hours_unpaid` math; `open_complications` Unable-first. 75 checks, all passing. The Draw Record `fields_json` was passed through ZenSched `_validate_fields` (9 fields, no signature, `show_if` option keys `unable` / `none`, photo `max_images` 2).

## Support

- ZenSched docs: <https://www.zensched.com/docs/>
- Tool reference: <https://www.zensched.com/docs/tools/>
- Feedback: ask your AI to call `feedback_submit` (categories: `bug`, `friction`, `missing_capability`, `docs`, `billing`, `feature`, `other`)

## License

MIT. See `LICENSE`.
