# Example Workflow: What the AI Does Behind Each Request

This shows the exact tool calls the agent makes for a first week at **River Mobile Draws**, following `SKILL.md`. The owner only types the quoted lines; everything else is the agent's work. Assumes setup from `QUICKSTART.md` is complete (both MCP servers configured, `schema.sql` loaded, `SKILL.md` given as instructions).

IDs and responses are illustrative. ZenSched IDs are integers. Watch what does **not** cross to ZenSched: patient names, DOB, MRN, fasting notes, special-draw notes, the door code, test menus. ZenSched sees `Draw 1 - Maple` / `Draw 2 - Cedar`, a street address, and a Draw Record with no names.

Timezone: Central, `-05:00`.

## Session start (every session)

```
sqlite_execute: PRAGMA foreign_keys = ON;
sqlite_query:   SELECT key, value FROM settings;
  → business_name = My Mobile Draws, timezone_offset = -05:00,
    default_draw_minutes = 30, invoice_due_days = 30, invoice_prefix = INV,
    draw_record_form_id = NULL, event_window_days = 60,
    default_bill_rate = 55.00, default_pay_rate = 22.00,
    default_checkin_radius_m = 75
sqlite_query:   SELECT * FROM open_complications;   → (none)
```

## "We're River Mobile Draws in Austin, Texas, Central time. We bill $55 a draw and pay $22 an hour unless I say otherwise."

```
sqlite_execute: UPDATE settings SET value = 'River Mobile Draws' WHERE key = 'business_name';
sqlite_execute: UPDATE settings SET value = '-05:00' WHERE key = 'timezone_offset';
sqlite_execute: UPDATE settings SET value = '55.00' WHERE key = 'default_bill_rate';
sqlite_execute: UPDATE settings SET value = '22.00' WHERE key = 'default_pay_rate';
```

> Saved. I'll schedule everything in Central time (-05:00). You don't have a Draw Record form yet; it's free to create. Tube count, cooler temp, fasting, outcome, complications — no patient name, no test names, no signature pad. Want me to set it up now?

Owner: *"yes"*

```
form_create:
  title: "Draw Record"
  idempotency_key: "form-draw-record"
  fields_json: (the JSON below, passed as one string)
```

```json
[
  {"type": "section", "label": "Draw record", "text": "Complete before you leave. Do not write the patient's name, MRN, diagnosis, or test names."},
  {"type": "number", "label": "Tube count", "identifier": "tube_count", "required": true},
  {"type": "number", "label": "Cooler temperature C", "identifier": "cooler_temp_c"},
  {"type": "select", "label": "Fasting", "identifier": "fasting", "required": true,
   "options": ["Yes", "No", "Not required"]},
  {"type": "select", "label": "Draw outcome", "identifier": "draw_outcome", "required": true,
   "options": ["Successful", "Partial", "Unable"]},
  {"type": "textarea", "label": "Unable reason", "identifier": "unable_reason",
   "show_if": {"field": "draw_outcome", "op": "equals", "value": "unable", "action": "show"}},
  {"type": "select", "label": "Complications", "identifier": "complications", "required": true,
   "options": ["None", "Hematoma", "Faint", "Other"]},
  {"type": "textarea", "label": "Complication notes", "identifier": "complication_notes",
   "show_if": {"field": "complications", "op": "not_equals", "value": "none", "action": "show"}},
  {"type": "photo", "label": "Tube labels", "identifier": "tube_labels", "max_images": 2, "stamp_photos": true}
]
```

```
  → form_id: 401, fields: [ ...8 fields echoed with identifiers tube_count, cooler_temp_c,
    fasting, draw_outcome, unable_reason, complications, complication_notes, tube_labels... ]

sqlite_execute: UPDATE settings SET value = '401' WHERE key = 'draw_record_form_id';
```

> Draw Record form created. I'll attach it to every address automatically. Photos of tube labels are optional — any submission with photos costs $0.15 to read later instead of $0.05. There is no signature step; they tap Submit.

## "Add a cash-pay clinic: Riverside Cash Clinic, billing@riverside.example, 512-555-0199, $55 a draw, net 15."

```
sqlite_execute:
  INSERT INTO clients (client_name, client_type, contact_email, contact_phone, bill_rate, payment_terms_days)
  VALUES ('Riverside Cash Clinic', 'cash', 'billing@riverside.example', '512-555-0199', 55.00, 15);
  → lastInsertRowid = 1
```

> Added Riverside Cash Clinic as a cash-pay client at $55/draw, net 15. Invoices go to billing@riverside.example and will use patient codes, not names.

## "Add a standing patient: Eleanor Briggs, 412 Maple Street, Austin TX 78704. DOB 1948-02-11, MRN RIV-4412, 512-555-0148. 12-hour fast, water ok. Hard stick — left antecubital preferred. Door code 1357. Mon/Wed/Fri 8:00 for 30 minutes starting Monday 9/7. Give her to Dana once she's invited."

```
sqlite_execute:
  INSERT INTO patients (client_id, patient_name, dob, mrn, phone, fasting_notes, special_draw_notes)
  VALUES (1, 'Eleanor Briggs', '1948-02-11', 'RIV-4412', '512-555-0148',
          '12-hour fast, water ok', 'Hard stick; left antecubital preferred');
  → lastInsertRowid = 1
  (trigger fills patient_code = 'P-0001')

sqlite_execute:
  INSERT INTO addresses (patient_id, address, city, state, zip, access_notes, zensched_label)
  VALUES (1, '412 Maple Street', 'Austin', 'TX', '78704', 'Door code 1357.', 'Draw 1 - Maple');
  → lastInsertRowid = 1

sqlite_execute:
  INSERT INTO draw_schedule (patient_id, address_id, client_id, weekdays, start_time, duration_minutes, start_date)
  VALUES (1, 1, 1, '1010100', '08:00', 30, '2026-09-07');
  → lastInsertRowid = 1
```

`preferred_worker_id` is left NULL; Dana has not been invited yet.

Agent (first metered call this session, rule 10):

> Creating the Maple address on ZenSched costs $0.03 for geocoding. If your account isn't funded yet you'll get a prompt for the $5 activation deposit. Go ahead?

Owner: *"yes"*

```
location_create:
  name: "Draw 1 - Maple"
  street_address: "412 Maple Street, Austin, TX 78704"
  checkin_radius_m: 75
  idempotency_key: "loc-address-1"
  → location_id: 9101, lat: 30.2501, lng: -97.7580, pin_quality: "street",
    radius_note: "Check-in radius is enforced by the talent policy ...",
    billing: { meter: "geocode", units: 1, price: 0.03 }
```

Nothing about the MRN, the fast, the hard stick, or the door code is in `name` or `notes`.

```
event_create:
  location_id: 9101
  title: "Draws - Draw 1 - Maple"
  start_date: "2026-09-07"
  end_date:   "2026-11-05"          ← start + 59 days (60-day cap)
  idempotency_key: "event-address-1-20260907"
  → event_id: 7101

form_assign:
  form_id: 401
  event_id: 7101
  idempotency_key: "assign-draw-record-7101"
  → status: "assigned", form_id: 401, event_id: 7101, policy_id: 0

sqlite_execute:
  UPDATE addresses SET zensched_location_id = 9101, zensched_event_id = 7101, event_valid_until = '2026-11-05'
  WHERE address_id = 1;
```

> Added Eleanor Briggs as P-0001, 412 Maple Street. Standing Mon/Wed/Fri 8:00–8:30 at $55/draw to Riverside. Her name, DOB, MRN, fasting notes, hard-stick note, and the door code are on your computer only; ZenSched knows the house as "Draw 1 - Maple". I'll assign Dana once she's invited. The ZenSched event runs through Nov 5.

## "Add a one-off Tuesday 10 to 11 at 88 Cedar Avenue, Austin TX 78704. Patient is Marcus Hale, DOB 1972-06-03, no MRN, not fasting. Cash clinic. Give him to Luis."

```
sqlite_execute:
  INSERT INTO patients (client_id, patient_name, dob, phone, fasting_notes, special_draw_notes)
  VALUES (1, 'Marcus Hale', '1972-06-03', NULL, 'Not fasting', NULL);
  → lastInsertRowid = 2
  (trigger fills patient_code = 'P-0002')

sqlite_execute:
  INSERT INTO addresses (patient_id, address, city, state, zip, zensched_label)
  VALUES (2, '88 Cedar Avenue', 'Austin', 'TX', '78704', 'Draw 2 - Cedar');
  → lastInsertRowid = 2

sqlite_execute:
  INSERT INTO draws (patient_id, address_id, client_id, draw_date, window_start, window_end, status)
  VALUES (2, 2, 1, '2026-09-08', '10:00', '11:00', 'scheduled');
  → lastInsertRowid = 1
  (trigger fills bill_rate 55.00, bill_amount 55.00, pay_rate 22.00)

location_create: name "Draw 2 - Cedar", street_address "88 Cedar Avenue, Austin, TX 78704",
                 checkin_radius_m 75, idempotency_key "loc-address-2"  → location_id 9102
event_create:    location_id 9102, title "Draws - Draw 2 - Cedar", start_date "2026-09-08",
                 end_date "2026-11-06", idempotency_key "event-address-2-20260908"  → event_id 7102
form_assign:     form_id 401, event_id 7102, idempotency_key "assign-draw-record-7102"
sqlite_execute:  UPDATE addresses SET zensched_location_id = 9102, zensched_event_id = 7102,
                 event_valid_until = '2026-11-06' WHERE address_id = 2;
```

No `draw_schedule` row. The one-off lives in `draws` with `schedule_id` NULL and will show up in `draws_due_this_week` as `source = 'one_off'`.

> Added Marcus Hale as P-0002. One-off Tuesday Sep 8, 10:00–11:00 at 88 Cedar. ZenSched label "Draw 2 - Cedar". I'll assign Luis once he's invited.

## "Invite Dana Okonkwo, dana@example.com, $24 an hour, she takes Maple. And Luis Ortega, luis@example.com, standard pay, he takes the Cedar one-off."

> Inviting two phlebotomists costs $0.50. OK?

Owner: *"yes"*

```
worker_invite:
  email: "dana@example.com"
  first_name: "Dana"
  last_name: "Okonkwo"
  idempotency_key: "worker-dana@example.com"
  → worker_id: 501, status: "invited", invitation_sent: true
    billing: { meter: "worker_invite", units: 1, price: 0.25 }

worker_invite: email "luis@example.com", first_name "Luis", last_name "Ortega",
               idempotency_key "worker-luis@example.com"  → worker_id: 502

sqlite_execute: INSERT INTO phlebs (phleb_name, email, zensched_worker_id, pay_rate)
                VALUES ('Dana Okonkwo', 'dana@example.com', 501, 24.00);   → 1
sqlite_execute: INSERT INTO phlebs (phleb_name, email, zensched_worker_id)
                VALUES ('Luis Ortega', 'luis@example.com', 502);           → 2
sqlite_execute: UPDATE draw_schedule SET preferred_worker_id = 501 WHERE schedule_id = 1;
sqlite_execute: UPDATE draws SET phleb_id = 2, zensched_worker_id = 502 WHERE draw_id = 1;
```

> Invited Dana and Luis. Each gets an email with the app link and an activation code. Dana is the regular for Maple (P-0001). Luis has the Cedar one-off (P-0002). Please give Dana the fasting notes, hard-stick note, and door code yourself; I keep those off ZenSched.

## "Schedule next week."

```
sqlite_query: SELECT * FROM draws_due_this_week;
  → 2026-09-07 | sched 1 | draw_id NULL | recurring | Eleanor Briggs | P-0001 | addr 1
               | Draw 1 - Maple | evt 7101 | event_needs_roll 0 | 08:00–08:30
               | worker 501 Dana Okonkwo | unassigned 0
               | start_iso 2026-09-07T08:00:00-05:00 | end_iso 2026-09-07T08:30:00-05:00
               | shift-address-1-20260907-0800
    2026-09-08 | sched NULL | draw_id 1 | one_off | Marcus Hale | P-0002 | addr 2
               | Draw 2 - Cedar | evt 7102 | event_needs_roll 0 | 10:00–11:00
               | worker 502 Luis Ortega | unassigned 0
               | start_iso 2026-09-08T10:00:00-05:00 | end_iso 2026-09-08T11:00:00-05:00
               | shift-draw-1
    2026-09-09 | sched 1 | recurring | P-0001 | 08:00 | shift-address-1-20260909-0800
    2026-09-11 | sched 1 | recurring | P-0001 | 08:00 | shift-address-1-20260911-0800
  (4 rows; Fri 9/11 is inside a 7-day window that includes it)

shift_create:
  event_id: 7101
  worker_id: 501
  start: "2026-09-07T08:00:00-05:00"
  end:   "2026-09-07T08:30:00-05:00"
  idempotency_key: "shift-address-1-20260907-0800"
  → shift_id: 89001, status: "scheduled", forms_installed: [401]

shift_create:
  event_id: 7102
  worker_id: 502
  start: "2026-09-08T10:00:00-05:00"
  end:   "2026-09-08T11:00:00-05:00"
  idempotency_key: "shift-draw-1"
  → shift_id: 89002, status: "scheduled", forms_installed: [401]

sqlite_execute:
  UPDATE draws SET zensched_shift_id = 89002, zensched_event_id = 7102,
                   zensched_worker_id = 502,
                   scheduled_start = '2026-09-08T10:00:00-05:00',
                   scheduled_end = '2026-09-08T11:00:00-05:00'
  WHERE draw_id = 1;

(... two more shift_create calls → 89003 Wed Maple, 89004 Fri Maple)
```

> Scheduled 4 draws for the week of Sep 7:
> - Dana: Mon, Wed, Fri 8:00–8:30 at Draw 1 - Maple (P-0001)
> - Luis: Tue 10:00–11:00 at Draw 2 - Cedar (P-0002)
>
> Both have been notified in the app and every draw has the Draw Record attached.

Standing shifts are not written to SQLite. The one-off already had a `draws` row; it now has `zensched_shift_id` 89002. Asking "schedule next week" again is safe: identical idempotency keys return the same four shifts.

## The phlebotomists do the work

Monday 7:58, at 412 Maple Street: Dana taps **Check in** (GPS: 9 m from the pin, verified, $0.10). Successful draw, 4 tubes, cooler 4.2 °C, fasting Yes, complications None. Optional tube-label photo × 1. **Submit** (no signature). **Check out** 8:22.

Tuesday 10:05, Luis at 88 Cedar Avenue. Two attempts, vein collapses, patient lightheaded. Draw Record: tube count 0, cooler 5.0 °C, fasting Not required, outcome **Unable**, unable_reason "Vein collapsed after two attempts; patient lightheaded, recovered seated.", complications **Faint**, complication_notes "Sat 5 min, water, no loss of consciousness." No photos. Check out 10:28.

Wednesday and Friday Maple: routine, 4 tubes, no photos Wednesday, two tube-label photos Friday.

## "Record this week's draws."

```
shift_list:
  date_from: "2026-09-07"
  date_to:   "2026-09-13"
  status:    "checked_out"
  → shifts: [
      { shift_id: 89001, event_id: 7101, worker_id: 501, date: "2026-09-07", start: "08:00", end: "08:30" },
      { shift_id: 89002, event_id: 7102, worker_id: 502, date: "2026-09-08", start: "10:00", end: "11:00" },
      { shift_id: 89003, event_id: 7101, worker_id: 501, date: "2026-09-09", ... },
      { shift_id: 89004, event_id: 7101, worker_id: 501, date: "2026-09-11", ... }
    ], count: 4

sqlite_query: SELECT zensched_shift_id FROM draws WHERE zensched_shift_id IN (89001, 89002, 89003, 89004);
  → 89002 only (the one-off stub)

timesheet_export:
  period: "2026-09-07:2026-09-13"
  mode:   "hours"
  format: "json"
  → rows: [
      { worker_id: 501, event_id: 7101, date: "2026-09-07", hours: 0.40, gps_verified: true },
      { worker_id: 502, event_id: 7102, date: "2026-09-08", hours: 0.38, gps_verified: true },
      { worker_id: 501, event_id: 7101, date: "2026-09-09", hours: 0.35, gps_verified: true },
      { worker_id: 501, event_id: 7101, date: "2026-09-11", hours: 0.42, gps_verified: true }
    ]
(free)

shift_status: shift_id 89001
  → actual_in "2026-09-07T07:58:00-05:00", actual_out "2026-09-07T08:22:00-05:00",
    punches: [ { type: "in", gps_verified: true, distance_from_site_m: 9 },
               { type: "out", gps_verified: true, distance_from_site_m: 7 } ]
(free; repeated for 89002–89004)
```

Agent (metered read, rule 10):

> There are 4 Draw Records to pull. Reading them costs $0.05 each, or $0.15 when they have tube-label photos. Two of the Maple draws have photos, so about $0.40 (2 × $0.15 + 2 × $0.05). I'll read them once and keep the summaries locally. OK?

Owner: *"go"*

```
form_export:
  form_id: 401
  since: "2026-09-07"
  until: "2026-09-13"
  format: "json"
  → row_count: 4, rows: [
      { submission_id: 4401, worker_id: 501, event_id: 7101, submitted_at: "2026-09-07 08:20:10",
        data: { tube_count: 4, cooler_temp_c: 4.2, fasting: "yes",
                draw_outcome: "successful", complications: "none" },
        media: [ { field: "tube_labels", cdn_url: "https://cdn.zensched.com/m/.../t1.jpg" } ] },
      { submission_id: 4402, worker_id: 502, event_id: 7102, submitted_at: "2026-09-08 10:26:40",
        data: { tube_count: 0, cooler_temp_c: 5.0, fasting: "not_required",
                draw_outcome: "unable",
                unable_reason: "Vein collapsed after two attempts; patient lightheaded, recovered seated.",
                complications: "faint",
                complication_notes: "Sat 5 min, water, no loss of consciousness." },
        media: [] },
      { submission_id: 4403, ... successful, 4 tubes, no photos },
      { submission_id: 4404, ... successful, 4 tubes, 2 photos }
    ]
    billing: { meter: "mixed", note: "2 form_media + 2 form_basic", price: 0.40 }

sqlite_execute:
  INSERT INTO draws (patient_id, address_id, client_id, schedule_id, zensched_worker_id, zensched_shift_id,
                     zensched_event_id, draw_date, window_start, window_end, scheduled_start, scheduled_end,
                     actual_in, actual_out, gps_verified, status, draw_outcome, tube_count, cooler_temp_c,
                     fasting_confirmed, complications, report_dc_id)
  VALUES (1, 1, 1, 1, 501, 89001, 7101,
          '2026-09-07', '08:00', '08:30', '2026-09-07T08:00:00-05:00', '2026-09-07T08:30:00-05:00',
          '2026-09-07T07:58:00-05:00', '2026-09-07T08:22:00-05:00', 1,
          'completed', 'successful', 4, 4.2, 'yes', 'none', 4401);
  (trigger fills: phleb_id 1, hours 0.40, bill_rate 55.00, pay_rate 24.00, bill_amount 55.00)

sqlite_execute:
  UPDATE draws SET actual_in = '2026-09-08T10:05:00-05:00', actual_out = '2026-09-08T10:28:00-05:00',
                   gps_verified = 1, hours = 0.38, status = 'completed', draw_outcome = 'unable',
                   unable_reason = 'Vein collapsed after two attempts; patient lightheaded, recovered seated.',
                   tube_count = 0, cooler_temp_c = 5.0, fasting_confirmed = 'not_required',
                   complications = 'faint',
                   complication_notes = 'Sat 5 min, water, no loss of consciousness.',
                   report_dc_id = 4402
  WHERE draw_id = 1;
  (hours passed explicitly — fill_draw_derived is INSERT-only)

(... two more INSERTs for Wed and Fri Maple, 89003 / 89004)
```

> Recorded 4 draws, all GPS-verified at the door.
>
> **Unable — Tuesday, P-0002 (Marcus Hale), Luis.** Outcome Unable, complications Faint: *"Vein collapsed after two attempts; patient lightheaded, recovered seated."* Notes: sat 5 min, water, no loss of consciousness. I still have this at the $55 trip fee for Riverside unless you want it written off.
>
> Everything else successful. Dana: Mon/Wed/Fri Maple, 4 tubes each, cooler 4.1–4.4 °C, fasting confirmed. Hours: Dana 1.17, Luis 0.38.

## "Anything I should worry about?"

```
sqlite_query: SELECT * FROM open_complications;
  → draw 1 | 2026-09-08 | unable | faint | P-0002 | Marcus Hale | Riverside Cash Clinic | Luis Ortega
    | "Vein collapsed after two attempts..." | report 4402
```

> One open item: Tuesday's Cedar draw (P-0002). Unable + faint, recovered. Want me to draft a note to Riverside that uses only the patient code?

## "Invoice Riverside — codes only."

```
sqlite_query: SELECT * FROM draws_to_invoice;
  → Riverside Cash Clinic | cash | billing@riverside.example | 4 draws | 220.00
    | patient_codes P-0001,P-0002 | 2026-09-07 .. 2026-09-11
  (no patient names in this view)

sqlite_execute:
  INSERT INTO invoices (client_id, invoice_date, due_date, draw_count, total_amount, line_items)
  SELECT v.client_id, date('now'),
         date('now', '+' || (SELECT payment_terms_days FROM clients WHERE client_id = 1) || ' days'),
         COUNT(v.draw_id), SUM(v.bill_amount),
         json_group_array(json_object('draw_id', v.draw_id, 'date', v.draw_date,
                                      'patient_code', p.patient_code, 'outcome', v.draw_outcome,
                                      'tubes', v.tube_count, 'amount', v.bill_amount))
  FROM draws v JOIN patients p ON p.patient_id = v.patient_id
  WHERE v.invoiced = 0 AND v.status = 'completed' AND v.client_id = 1
  GROUP BY v.client_id;

sqlite_execute: UPDATE draws SET invoiced = 1 WHERE invoiced = 0 AND status = 'completed' AND client_id = 1;
sqlite_query:   SELECT invoice_number, due_date, draw_count, total_amount FROM invoices
                WHERE invoice_id = last_insert_rowid();
  → INV-2026-0001 | 2026-09-28 | 4 | 220.00
```

> Here's the Riverside invoice. Patient codes only.
>
> ```
> River Mobile Draws
> Invoice INV-2026-0001
> To: Riverside Cash Clinic (billing@riverside.example)
> Date: Sep 13, 2026    Due: Sep 28, 2026
>
>   Mon Sep 7    P-0001    successful    4 tubes    $55.00
>   Tue Sep 8    P-0002    unable        0 tubes    $55.00
>   Wed Sep 9    P-0001    successful    4 tubes    $55.00
>   Fri Sep 11   P-0001    successful    4 tubes    $55.00
>
> Draws: 4
> Total due: $220.00
> Each visit was GPS-verified at the draw address.
> ```
>
> Say "sent" when this is out. Say the word if you want the Unable line written off before they see it.

No names, no MRNs, no test names.

## "Run payroll for last week."

```
sqlite_query: SELECT * FROM payroll_hours_unpaid;
  → Dana Okonkwo | worker 501 | 3 draws | 1.17 h | gross 28.08 | 2026-09-07 .. 2026-09-11
    Luis Ortega  | worker 502 | 1 draw  | 0.38 h | gross  8.36 | 2026-09-08 .. 2026-09-08
```

Hours match the free `timesheet_export`.

> Payroll for Sep 7–13:
>
> ```
> Dana Okonkwo   1.17 h  x  $24.00  =  $28.08   (Maple Mon/Wed/Fri)
> Luis Ortega    0.38 h  x  $22.00  =   $8.36   (Cedar Tue — Unable)
> Total gross                          $36.44
> ```
>
> All four shifts GPS-verified in and out. Say "paid" when payroll is done.

Owner: *"paid"*

```
sqlite_execute: UPDATE draws SET paid_out = 1 WHERE paid_out = 0 AND status = 'completed'
                AND draw_date BETWEEN '2026-09-07' AND '2026-09-13';
```

## Eight weeks later: "Schedule next week."

```
sqlite_query: SELECT * FROM draws_due_this_week;
  → 2026-11-06 | sched 1 | P-0001 | addr 1 | evt 7101 | event_valid_until 2026-11-05 | event_needs_roll 1 | ...

sqlite_query: SELECT * FROM event_needs_roll;
  → addr 1 | P-0001 | Draw 1 - Maple | evt 7101 | event_valid_until 2026-11-05

event_create:
  location_id: 9101
  title: "Draws - Draw 1 - Maple"
  start_date: "2026-11-06"
  end_date:   "2027-01-04"
  idempotency_key: "event-address-1-20261106"
  → event_id: 7250

form_assign: form_id 401, event_id 7250, idempotency_key "assign-draw-record-7250"
sqlite_execute: UPDATE addresses SET zensched_event_id = 7250, event_valid_until = '2027-01-04' WHERE address_id = 1;

shift_create: event_id 7250 for the Nov 6 Maple slot, key "shift-address-1-20261106-0800"
```

> Scheduled the week. Maple's ZenSched event expired Nov 5, so I renewed it through Jan 4. Nothing changes for Dana.

## Summary of who stored what

| Thing | Where | Why |
|---|---|---|
| Eleanor's and Marcus's names, DOB, MRN, phone, fasting notes, special-draw notes | SQLite **only** | PHI; ZenSched has no BAA |
| Door code | SQLite **only** | Privacy; never sent to ZenSched |
| Riverside contact, cash type, $55/draw | SQLite | Billing; ZenSched does not model labs or rates |
| Patient codes P-0001 / P-0002 | SQLite | The only identifier on invoices |
| Standing Mon/Wed/Fri cadence, preferred phlebotomist | SQLite | Recurrence; ZenSched does not model it |
| Dana's and Luis's pay rates | SQLite | Payroll |
| "Draw 1 - Maple" / "Draw 2 - Cedar" and the street addresses, GPS pins | ZenSched (IDs in `addresses`) | Needed for geofenced check-in; de-identified labels |
| Each home's current ≤60-day event and its end date | ZenSched (ID + `event_valid_until` in `addresses`) | Shifts hang off events; rolled by the agent |
| The Draw Record form | ZenSched (ID in `settings`) | Installed on the phone per shift |
| Dana, Luis, their invites, their apps | ZenSched (integer IDs in `phlebs`) | Workforce |
| The week's four shifts | ZenSched only (one-off also referenced from `draws`) | Live schedule |
| GPS punches, actual in/out, distance from the door | ZenSched only | Verified record; stamps copied onto `draws` |
| Four Draw Records (two with photos) | ZenSched (originals); tube count / outcome / complications in `draws` | Read once (metered; photos = media), then answered from SQLite |
| Four `draws` rows, payroll `paid_out`, one invoice with codes only | SQLite | Money |
