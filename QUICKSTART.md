# Quickstart

Setup is about 15 minutes, once. After that everything is plain English to your AI. Each step below tells you what to do and, where relevant, exactly what to type to the AI.

You need: Claude Desktop (or Cursor) and [Node.js LTS](https://nodejs.org/) installed. Nothing else.

Before you start, read the "HIPAA and what this kit is not" section of `README.md`. Short version: patient name, DOB, MRN, fasting notes, and door codes stay on your computer; ZenSched only ever sees a label like `Draw 12 - Maple`, a street address, and a Draw Record with no names or test names; there is no BAA and this is not a LIMS.

## 1. Make a data folder

Create a folder such as `C:\Users\YourName\phleb-ops` (Windows) or `/Users/yourname/phleb-ops` (Mac). Note the full path. It will hold patient health information, so keep it on an encrypted, backed-up disk.

## 2. Add the two tools to your AI's config

Open the config file:

- **Claude Desktop, Windows:** `%APPDATA%\Claude\claude_desktop_config.json`
- **Claude Desktop, Mac:** `~/Library/Application Support/Claude/claude_desktop_config.json`
- **Cursor:** Settings → MCP → Add new global MCP server

Paste this in and fix only the `SQLITE_PATH` line to match your folder from step 1:

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

- On Windows, double every backslash: `"C:\\Users\\YourName\\phleb-ops\\phleb-ops.db"`.
- Leave `zsc_your_key_here` as it is. You get the real key in the next step.

Save, then **fully quit and reopen** the AI app.

## 3. Create your ZenSched account

Type to the AI:

> Call zensched_guide, then account_create with org_name "River Mobile Draws". Show me the zsc_ key.

Copy the key into the config file in place of `zsc_your_key_here`. Save. Quit and reopen the app once more. (You can also ask the AI to call `account_use_key` with the key to continue right away, but update the file anyway so it sticks.)

## 4. Create the database tables

Copy the full contents of `schema.sql` and paste it into the chat with this line above it:

> Create these tables in my phleb-ops database. Run each statement one at a time with the SQLite tool, then list the tables to confirm.

## 5. Give the AI its instructions

Paste `SKILL.md` into the AI as standing instructions (Claude Desktop: a Project's instructions; Cursor: a rule). Then:

> We're River Mobile Draws in Austin, Texas, Central time. We bill $55 a draw and pay $22 an hour unless I say otherwise. Save that to settings and create the Draw Record form.

The AI saves your settings and calls `form_create` once (free) to build the Draw Record: tube count, cooler temperature, fasting, outcome (Successful / Partial / Unable), complications, optional tube-label photos. It collects no patient name and no test names. There is no signature field. It stores the form id so every address gets it.

## 6. Add the cash-pay clinic, then the first patient

> Add a cash-pay clinic: Riverside Cash Clinic, billing@riverside.example, 512-555-0199, $55 a draw, net 15.

> Add a standing patient: Eleanor Briggs, 412 Maple Street, Austin TX 78704. DOB 1948-02-11, MRN RIV-4412, 512-555-0148. 12-hour fast, water ok. Hard stick — left antecubital preferred. Door code 1357. Mon/Wed/Fri 8:00 for 30 minutes starting Monday 2026-09-07.

Behind the scenes the AI inserts the clinic, the patient (name, DOB, MRN, fasting and special-draw notes all local), assigns `P-0001`, and the standing schedule; calls `location_create` for "Draw 1 - Maple" (geocode, $0.03, may trigger the $5 activation deposit the first time); creates a 60-day `event_create` for the home; attaches the Draw Record with `form_assign`; and saves the IDs. ZenSched never sees her name, MRN, or door code. You just see a confirmation.

## 7. Invite your phlebotomists

> Invite Dana Okonkwo, dana@example.com, $24 an hour. She takes the Maple standing draws.

Dana gets an email ($0.25), installs the app ([Android](https://play.google.com/store/apps/details?id=com.zensched.app) / [iOS TestFlight](https://testflight.apple.com/join/Wp51m5Yq)), and activates. Give her the fasting notes, special-draw notes, and door code yourself; the AI will not put them in ZenSched.

## 8. Schedule the week

> Schedule next week.

The AI expands the standing mask plus any one-offs for the next 7 days, gives each draw to the preferred phlebotomist, creates one shift per draw on ZenSched, and summarizes by person and day. Dana gets a push notification for each, with the Draw Record attached. She checks in at the door (GPS-verified), draws, enters tube count and cooler temp, taps Submit, and checks out.

## 9. After the work is done

> Record this week's draws.

The AI pulls the completed, GPS-verified shifts and their times from ZenSched (free), then the Draw Records (metered — $0.05, or $0.15 with tube-label photos — so it tells you the cost first), saves a per-draw summary, and leads with any Unable or complication.

> Invoice Riverside — codes only.

A plain-text invoice to the clinic with one line per draw (date, **P-0001**, outcome, tubes, amount). No patient names.

> Run payroll for last week.

Verified hours per phlebotomist times their pay rate, cross-checked against ZenSched's free hours export. Say "paid" and it marks those hours done.

## What next

- `README.md` for the full explanation, the HIPAA / not-a-LIMS boundaries, troubleshooting table, and developer notes
- `example-workflow.md` to see the exact tool calls behind a first week at River Mobile Draws (two patients, two phlebotomists, one Unable, invoice by code)
