-- ZenSched Mobile-Phlebotomy Local Database Schema
-- SQLite database for lab/trial/employer clients, local-only patient records,
-- draw addresses, phlebotomist roster, optional standing recurrence, completed
-- and one-off draws, payroll hours, and lab invoicing by patient code.
-- DO NOT duplicate live schedule data from ZenSched (shifts, punches, timesheets).
--
-- HOW TO LOAD THIS FILE
--   Normal path: paste this whole file into your AI chat and say
--   "Create these tables in my phleb-ops database. Run each statement one at a time."
--   The AI runs each statement through the SQLite MCP tool (sqlite_execute).
--   Most SQLite MCP tools accept ONE statement per call, so every statement
--   below ends with a semicolon and stands alone.
--
--   Alternative (if you have the sqlite3 command-line tool):
--     sqlite3 phleb-ops.db < schema.sql
--
-- Every statement is idempotent (IF NOT EXISTS / INSERT OR IGNORE), so it is
-- safe to run this file again on an existing database.
--
-- THIS IS NOT A LIMS. There is no accessioning, no test menu, no specimen
-- tracking beyond a tube count and cooler temperature, no result reporting,
-- and no analyzer or lab-system interface. Order what to draw somewhere else.
--
-- HIPAA: ZenSched does not sign a Business Associate Agreement. Patient name,
-- date of birth, MRN, phone, fasting notes, special-draw notes, and door/access
-- notes live ONLY in this file on your computer. The ONLY string sent to
-- ZenSched about a patient is addresses.zensched_label (e.g. 'Draw 12 - Maple').
-- Never send a test menu, a diagnosis, or an MRN. SKILL.md makes this a hard
-- rule. Invoices to the lab use patients.patient_code, never the name.

-- Foreign keys are OFF by default in SQLite. This must be run once per
-- connection for ON DELETE CASCADE to work. SKILL.md tells the agent to run it
-- at the start of each session.
PRAGMA foreign_keys = ON;

-- Settings: small key/value store so the agent does not have to be re-told the
-- basics every session (timezone, per-draw bill rate, hourly pay, form id).
CREATE TABLE IF NOT EXISTS settings (
  key TEXT PRIMARY KEY,
  value TEXT
);

INSERT OR IGNORE INTO settings (key, value) VALUES ('business_name', 'My Mobile Draws');
INSERT OR IGNORE INTO settings (key, value) VALUES ('timezone_offset', '-05:00');
INSERT OR IGNORE INTO settings (key, value) VALUES ('default_draw_minutes', '30');
INSERT OR IGNORE INTO settings (key, value) VALUES ('invoice_due_days', '30');
INSERT OR IGNORE INTO settings (key, value) VALUES ('invoice_prefix', 'INV');
INSERT OR IGNORE INTO settings (key, value) VALUES ('draw_record_form_id', NULL);
INSERT OR IGNORE INTO settings (key, value) VALUES ('event_window_days', '60');
INSERT OR IGNORE INTO settings (key, value) VALUES ('default_bill_rate', '55.00');
INSERT OR IGNORE INTO settings (key, value) VALUES ('default_pay_rate', '22.00');
INSERT OR IGNORE INTO settings (key, value) VALUES ('default_checkin_radius_m', '75');

-- Clients: who pays you. A reference lab, a trial site, an employer/occupational
-- health program, a concierge clinic, or a cash-pay clinic. bill_rate is $ per
-- draw (flat), not hourly. Invoices go to this row, never to the patient.
CREATE TABLE IF NOT EXISTS clients (
  client_id INTEGER PRIMARY KEY AUTOINCREMENT,
  client_name TEXT NOT NULL,
  client_type TEXT NOT NULL DEFAULT 'lab'
    CHECK (client_type IN ('lab', 'trial', 'employer', 'concierge', 'cash')),
  contact_name TEXT,
  contact_email TEXT,
  contact_phone TEXT,
  bill_rate REAL,                                   -- $ per draw; NULL = settings.default_bill_rate
  payment_terms_days INTEGER NOT NULL DEFAULT 30,
  is_active INTEGER DEFAULT 1,
  notes TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now'))
);

-- Patients: the people you draw. Every health identifier is LOCAL ONLY and
-- never leaves this database. patient_code (P-0001) is the only identifier
-- that may appear on a lab invoice.
CREATE TABLE IF NOT EXISTS patients (
  patient_id INTEGER PRIMARY KEY AUTOINCREMENT,
  client_id INTEGER NOT NULL,                       -- default billing client (the lab / clinic)
  patient_name TEXT NOT NULL,                       -- LOCAL ONLY
  patient_code TEXT UNIQUE,                         -- 'P-0001'; trigger fills if NULL
  dob TEXT,                                         -- LOCAL ONLY: ISO date
  mrn TEXT,                                         -- LOCAL ONLY
  phone TEXT,                                       -- LOCAL ONLY
  fasting_notes TEXT,                               -- LOCAL ONLY: '12h fast, water ok'
  special_draw_notes TEXT,                          -- LOCAL ONLY: hard stick, port, mastectomy side
  is_active INTEGER DEFAULT 1,
  notes TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (client_id) REFERENCES clients(client_id)
);

-- Addresses: where the draw happens, with ZenSched references.
-- One ZenSched LOCATION per address, created once and kept forever.
-- One ZenSched EVENT per address per rolling window of at most 60 days
-- (ZenSched caps event length). zensched_event_id is the CURRENT event and
-- event_valid_until is its last valid date. When a draw date is later than
-- event_valid_until, the agent creates a new event and updates both columns.
-- zensched_label is the ONLY name sent to ZenSched for this home
-- (e.g. 'Draw 12 - Maple'); the patient name, MRN, and draw notes stay here.
CREATE TABLE IF NOT EXISTS addresses (
  address_id INTEGER PRIMARY KEY AUTOINCREMENT,
  patient_id INTEGER NOT NULL,
  label TEXT,                                       -- 'Home', 'Daughter''s house', 'SNF'
  address TEXT NOT NULL,
  address_line2 TEXT,
  city TEXT,
  state TEXT,
  zip TEXT,
  access_notes TEXT,                                -- LOCAL ONLY: door code, gate, parking, dog
  zensched_label TEXT,                              -- de-identified name used on ZenSched
  zensched_location_id INTEGER,                     -- from location_create (permanent)
  zensched_event_id INTEGER,                        -- from event_create (current <=60-day window)
  event_valid_until TEXT,                           -- ISO date: last day the current event covers
  is_active INTEGER DEFAULT 1,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (patient_id) REFERENCES patients(patient_id) ON DELETE CASCADE
);

-- Phlebotomists: your roster. zensched_worker_id comes from worker_invite.
CREATE TABLE IF NOT EXISTS phlebs (
  phleb_id INTEGER PRIMARY KEY AUTOINCREMENT,
  phleb_name TEXT NOT NULL,
  email TEXT,
  phone TEXT,
  zensched_worker_id INTEGER UNIQUE,                -- from worker_invite
  pay_rate REAL,                                    -- $/hour; NULL = settings.default_pay_rate
  is_active INTEGER DEFAULT 1,
  notes TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now'))
);

-- Draw schedule: optional standing recurrence for homebound patients
-- ("Maple: Mon/Wed/Fri 08:00, 30 min"). weekdays is a 7-character mask,
-- Monday first: '1010100' = Mon/Wed/Fri. A patient with a morning AND an
-- afternoon draw gets two rows. preferred_worker_id is the ZenSched worker
-- id of the phlebotomist who should get this slot. The agent expands this
-- table into real ZenSched shifts once a week using draws_due_this_week.
CREATE TABLE IF NOT EXISTS draw_schedule (
  schedule_id INTEGER PRIMARY KEY AUTOINCREMENT,
  patient_id INTEGER NOT NULL,
  address_id INTEGER NOT NULL,
  client_id INTEGER NOT NULL,
  weekdays TEXT NOT NULL
    CHECK (length(weekdays) = 7 AND weekdays NOT GLOB '*[^01]*'),
  start_time TEXT NOT NULL                          -- 'HH:MM' 24-hour local time
    CHECK (start_time GLOB '[0-2][0-9]:[0-5][0-9]'),
  duration_minutes INTEGER NOT NULL DEFAULT 30
    CHECK (duration_minutes BETWEEN 15 AND 240),
  preferred_worker_id INTEGER,                      -- ZenSched worker id; NULL = last phleb / ask
  start_date TEXT,                                  -- first date this applies (NULL = already running)
  end_date TEXT,                                    -- last date (NULL = open-ended)
  is_active INTEGER DEFAULT 1,
  notes TEXT,                                       -- operational only: 'use side door' — never PHI
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (patient_id) REFERENCES patients(patient_id) ON DELETE CASCADE,
  FOREIGN KEY (address_id) REFERENCES addresses(address_id) ON DELETE CASCADE,
  FOREIGN KEY (client_id) REFERENCES clients(client_id)
);

-- Draws: one row per booked or completed draw. Recurring dates are expanded
-- by draws_due_this_week and INSERTed here when recorded (or when you want a
-- stub). One-offs are INSERTed as status='scheduled' at booking time, then
-- UPDATEd when the Draw Record is pulled. window_start / window_end are the
-- arrival window (HH:MM). hours is GPS time on site (payroll). bill_amount
-- is the flat per-draw fee to the lab (trigger fills from the client).
CREATE TABLE IF NOT EXISTS draws (
  draw_id INTEGER PRIMARY KEY AUTOINCREMENT,
  patient_id INTEGER NOT NULL,
  address_id INTEGER NOT NULL,
  client_id INTEGER NOT NULL,
  schedule_id INTEGER,                              -- NULL = one-off
  phleb_id INTEGER,
  zensched_worker_id INTEGER,
  zensched_shift_id INTEGER UNIQUE,                 -- prevents recording the same shift twice
  zensched_event_id INTEGER,
  draw_date TEXT NOT NULL,                          -- ISO date of the window start
  window_start TEXT                                 -- 'HH:MM' arrival-window start
    CHECK (window_start IS NULL OR window_start GLOB '[0-2][0-9]:[0-5][0-9]'),
  window_end TEXT                                   -- 'HH:MM' arrival-window end
    CHECK (window_end IS NULL OR window_end GLOB '[0-2][0-9]:[0-5][0-9]'),
  scheduled_start TEXT,                             -- ISO datetime with offset
  scheduled_end TEXT,
  actual_in TEXT,
  actual_out TEXT,
  gps_verified INTEGER,                             -- 1 if both punches were on site
  status TEXT NOT NULL DEFAULT 'scheduled'
    CHECK (status IN ('scheduled', 'checked_in', 'completed', 'cancelled', 'missed')),
  draw_outcome TEXT
    CHECK (draw_outcome IS NULL OR draw_outcome IN ('successful', 'partial', 'unable')),
  unable_reason TEXT,
  tube_count INTEGER,
  cooler_temp_c REAL,
  fasting_confirmed TEXT
    CHECK (fasting_confirmed IS NULL OR fasting_confirmed IN ('yes', 'no', 'not_required')),
  complications TEXT NOT NULL DEFAULT 'none'
    CHECK (complications IN ('none', 'hematoma', 'faint', 'other')),
  complication_notes TEXT,
  hours REAL,                                       -- payable hours (trigger fills if NULL)
  bill_rate REAL,                                   -- $ per draw snapshot at insert
  bill_amount REAL,                                 -- flat fee (trigger fills if NULL)
  pay_rate REAL,                                    -- $/h snapshot at insert
  report_dc_id INTEGER,                             -- Draw Record submission_id
  invoiced INTEGER DEFAULT 0,
  paid_out INTEGER DEFAULT 0,
  created_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (patient_id) REFERENCES patients(patient_id) ON DELETE CASCADE,
  FOREIGN KEY (address_id) REFERENCES addresses(address_id) ON DELETE CASCADE,
  FOREIGN KEY (schedule_id) REFERENCES draw_schedule(schedule_id) ON DELETE SET NULL,
  FOREIGN KEY (client_id) REFERENCES clients(client_id),
  FOREIGN KEY (phleb_id) REFERENCES phlebs(phleb_id) ON DELETE SET NULL
);

-- Invoices: billed to the CLIENT (the lab / clinic), never to the patient.
-- invoice_number is filled in automatically by a trigger if left NULL.
-- line_items MUST use patient_code, never patient_name.
CREATE TABLE IF NOT EXISTS invoices (
  invoice_id INTEGER PRIMARY KEY AUTOINCREMENT,
  client_id INTEGER NOT NULL,
  invoice_number TEXT UNIQUE,                       -- human-readable: 'INV-2026-0001'
  invoice_date TEXT NOT NULL,
  due_date TEXT,
  draw_count INTEGER,
  total_amount REAL NOT NULL,
  paid INTEGER DEFAULT 0,
  paid_date TEXT,
  sent_date TEXT,
  line_items TEXT,                                  -- JSON: date, patient_code, outcome, tubes, amount
  notes TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (client_id) REFERENCES clients(client_id)
);

-- Indexes for common queries
CREATE INDEX IF NOT EXISTS idx_patients_client ON patients(client_id);
CREATE INDEX IF NOT EXISTS idx_patients_code ON patients(patient_code);
CREATE INDEX IF NOT EXISTS idx_addresses_patient ON addresses(patient_id);
CREATE INDEX IF NOT EXISTS idx_addresses_zensched_event ON addresses(zensched_event_id);
CREATE INDEX IF NOT EXISTS idx_addresses_zensched_location ON addresses(zensched_location_id);
CREATE INDEX IF NOT EXISTS idx_schedule_patient ON draw_schedule(patient_id, is_active);
CREATE INDEX IF NOT EXISTS idx_schedule_address ON draw_schedule(address_id);
CREATE INDEX IF NOT EXISTS idx_draws_patient_date ON draws(patient_id, draw_date);
CREATE INDEX IF NOT EXISTS idx_draws_schedule_date ON draws(schedule_id, draw_date);
CREATE INDEX IF NOT EXISTS idx_draws_phleb ON draws(phleb_id, paid_out);
CREATE INDEX IF NOT EXISTS idx_draws_invoiced ON draws(invoiced);
CREATE INDEX IF NOT EXISTS idx_draws_status ON draws(status, draw_date);
CREATE INDEX IF NOT EXISTS idx_draws_complications ON draws(complications, draw_date);
CREATE INDEX IF NOT EXISTS idx_invoices_client ON invoices(client_id);
CREATE INDEX IF NOT EXISTS idx_invoices_paid ON invoices(paid);

-- Keep updated_at current
CREATE TRIGGER IF NOT EXISTS update_client_timestamp
AFTER UPDATE ON clients
BEGIN
  UPDATE clients SET updated_at = datetime('now') WHERE client_id = NEW.client_id;
END;

CREATE TRIGGER IF NOT EXISTS update_patient_timestamp
AFTER UPDATE ON patients
BEGIN
  UPDATE patients SET updated_at = datetime('now') WHERE patient_id = NEW.patient_id;
END;

CREATE TRIGGER IF NOT EXISTS update_address_timestamp
AFTER UPDATE ON addresses
BEGIN
  UPDATE addresses SET updated_at = datetime('now') WHERE address_id = NEW.address_id;
END;

CREATE TRIGGER IF NOT EXISTS update_phleb_timestamp
AFTER UPDATE ON phlebs
BEGIN
  UPDATE phlebs SET updated_at = datetime('now') WHERE phleb_id = NEW.phleb_id;
END;

CREATE TRIGGER IF NOT EXISTS update_schedule_timestamp
AFTER UPDATE ON draw_schedule
BEGIN
  UPDATE draw_schedule SET updated_at = datetime('now') WHERE schedule_id = NEW.schedule_id;
END;

-- Auto-assign P-0001, P-0002, ... when the agent leaves patient_code NULL.
CREATE TRIGGER IF NOT EXISTS fill_patient_code
AFTER INSERT ON patients
WHEN NEW.patient_code IS NULL
BEGIN
  UPDATE patients
  SET patient_code = 'P-' || printf('%04d', NEW.patient_id)
  WHERE patient_id = NEW.patient_id;
END;

-- Fill derived draw columns when the agent leaves them NULL:
--   phleb_id    <- phlebs row whose zensched_worker_id matches
--   bill_rate   <- clients.bill_rate, else settings.default_bill_rate
--   pay_rate    <- phlebs.pay_rate, else settings.default_pay_rate
--   hours       <- actual_out - actual_in (2 dp), else scheduled_end - scheduled_start
--   bill_amount <- bill_rate (flat per draw, not hours × rate)
-- SQLite date functions understand ISO strings with a '-05:00' style offset.
CREATE TRIGGER IF NOT EXISTS fill_draw_derived
AFTER INSERT ON draws
BEGIN
  UPDATE draws
  SET phleb_id = COALESCE(NEW.phleb_id,
                          (SELECT phleb_id FROM phlebs WHERE zensched_worker_id = NEW.zensched_worker_id)),
      bill_rate = COALESCE(NEW.bill_rate,
                           (SELECT bill_rate FROM clients WHERE client_id = NEW.client_id),
                           (SELECT CAST(value AS REAL) FROM settings WHERE key = 'default_bill_rate')),
      pay_rate = COALESCE(NEW.pay_rate,
                          (SELECT pay_rate FROM phlebs WHERE phleb_id = COALESCE(NEW.phleb_id,
                             (SELECT phleb_id FROM phlebs WHERE zensched_worker_id = NEW.zensched_worker_id))),
                          (SELECT CAST(value AS REAL) FROM settings WHERE key = 'default_pay_rate')),
      hours = COALESCE(NEW.hours,
                       CASE WHEN NEW.actual_in IS NOT NULL AND NEW.actual_out IS NOT NULL
                            THEN round((julianday(NEW.actual_out) - julianday(NEW.actual_in)) * 24.0, 2) END,
                       CASE WHEN NEW.scheduled_start IS NOT NULL AND NEW.scheduled_end IS NOT NULL
                            THEN round((julianday(NEW.scheduled_end) - julianday(NEW.scheduled_start)) * 24.0, 2) END)
  WHERE draw_id = NEW.draw_id;
  UPDATE draws
  SET bill_amount = COALESCE(NEW.bill_amount, round(bill_rate, 2))
  WHERE draw_id = NEW.draw_id;
END;

-- Auto-number invoices: INV-2026-0001, INV-2026-0002, ...
CREATE TRIGGER IF NOT EXISTS number_invoice
AFTER INSERT ON invoices
WHEN NEW.invoice_number IS NULL
BEGIN
  UPDATE invoices
  SET invoice_number = (SELECT COALESCE(value, 'INV') FROM settings WHERE key = 'invoice_prefix')
                       || '-' || strftime('%Y', NEW.invoice_date)
                       || '-' || printf('%04d', NEW.invoice_id)
  WHERE invoice_id = NEW.invoice_id;
END;

-- Draws that should happen in the next 7 days (today + 6), local calendar:
--   1) standing recurrence expanded from draw_schedule, minus dates already
--      in draws for that schedule_id
--   2) one-off draws (schedule_id IS NULL) still scheduled / checked_in
-- One row = one shift_create (or a reminder that the shift already exists).
-- Columns ending in _iso are ready to pass as shift_create start/end.
-- worker_id = preferred_worker_id, else the phleb who most recently did this
-- schedule row (continuity), else the one-off's assigned worker, else NULL
-- (unassigned = 1: the agent must ask).
-- event_needs_roll = 1 means create a new ZenSched event first (see SKILL.md).
CREATE VIEW IF NOT EXISTS draws_due_this_week AS
WITH RECURSIVE days(d) AS (
  SELECT date('now', 'localtime')
  UNION ALL
  SELECT date(d, '+1 day') FROM days WHERE d < date('now', 'localtime', '+6 days')
)
SELECT
  days.d                                     AS draw_date,
  s.schedule_id,
  CAST(NULL AS INTEGER)                      AS draw_id,
  'recurring'                                AS source,
  p.patient_id,
  p.patient_name,
  p.patient_code,
  cl.client_id,
  cl.client_name,
  a.address_id,
  a.address,
  a.city,
  a.zensched_label,
  a.zensched_location_id,
  a.zensched_event_id,
  a.event_valid_until,
  CASE WHEN a.event_valid_until IS NULL OR a.event_valid_until < days.d THEN 1 ELSE 0 END AS event_needs_roll,
  s.start_time                               AS window_start,
  strftime('%H:%M', datetime('2000-01-01 ' || s.start_time || ':00', '+' || s.duration_minutes || ' minutes')) AS window_end,
  s.duration_minutes,
  COALESCE(s.preferred_worker_id,
           (SELECT v.zensched_worker_id FROM draws v
             WHERE v.schedule_id = s.schedule_id AND v.zensched_worker_id IS NOT NULL
             ORDER BY v.draw_date DESC LIMIT 1)) AS worker_id,
  (SELECT ph.phleb_name FROM phlebs ph
    WHERE ph.zensched_worker_id = COALESCE(s.preferred_worker_id,
           (SELECT v.zensched_worker_id FROM draws v
             WHERE v.schedule_id = s.schedule_id AND v.zensched_worker_id IS NOT NULL
             ORDER BY v.draw_date DESC LIMIT 1))) AS phleb_name,
  CASE WHEN COALESCE(s.preferred_worker_id,
           (SELECT v.zensched_worker_id FROM draws v
             WHERE v.schedule_id = s.schedule_id AND v.zensched_worker_id IS NOT NULL
             ORDER BY v.draw_date DESC LIMIT 1)) IS NULL THEN 1 ELSE 0 END AS unassigned,
  days.d || 'T' || s.start_time || ':00' || (SELECT value FROM settings WHERE key = 'timezone_offset') AS start_iso,
  strftime('%Y-%m-%dT%H:%M:%S', datetime(days.d || ' ' || s.start_time || ':00', '+' || s.duration_minutes || ' minutes'))
    || (SELECT value FROM settings WHERE key = 'timezone_offset') AS end_iso,
  'shift-address-' || a.address_id || '-' || strftime('%Y%m%d', days.d) || '-' || replace(s.start_time, ':', '') AS idempotency_key,
  CAST(NULL AS INTEGER)                      AS zensched_shift_id,
  s.notes                                    AS schedule_notes
FROM days
JOIN draw_schedule s
  ON s.is_active = 1
 AND substr(s.weekdays, CASE strftime('%w', days.d) WHEN '0' THEN 7 ELSE CAST(strftime('%w', days.d) AS INTEGER) END, 1) = '1'
 AND (s.start_date IS NULL OR s.start_date <= days.d)
 AND (s.end_date IS NULL OR s.end_date >= days.d)
JOIN patients p ON p.patient_id = s.patient_id AND p.is_active = 1
JOIN clients cl ON cl.client_id = s.client_id AND cl.is_active = 1
JOIN addresses a ON a.address_id = s.address_id AND a.is_active = 1
WHERE NOT EXISTS (
  SELECT 1 FROM draws v WHERE v.schedule_id = s.schedule_id AND v.draw_date = days.d
)
UNION ALL
SELECT
  d.draw_date,
  d.schedule_id,
  d.draw_id,
  'one_off'                                  AS source,
  p.patient_id,
  p.patient_name,
  p.patient_code,
  cl.client_id,
  cl.client_name,
  a.address_id,
  a.address,
  a.city,
  a.zensched_label,
  a.zensched_location_id,
  a.zensched_event_id,
  a.event_valid_until,
  CASE WHEN a.event_valid_until IS NULL OR a.event_valid_until < d.draw_date THEN 1 ELSE 0 END AS event_needs_roll,
  d.window_start,
  d.window_end,
  CAST(round((julianday(d.draw_date || ' ' || COALESCE(d.window_end, d.window_start) || ':00')
              - julianday(d.draw_date || ' ' || COALESCE(d.window_start, '08:00') || ':00')) * 1440) AS INTEGER) AS duration_minutes,
  COALESCE(d.zensched_worker_id, ph.zensched_worker_id) AS worker_id,
  ph.phleb_name,
  CASE WHEN COALESCE(d.zensched_worker_id, ph.zensched_worker_id) IS NULL THEN 1 ELSE 0 END AS unassigned,
  d.draw_date || 'T' || COALESCE(d.window_start, '08:00') || ':00' || (SELECT value FROM settings WHERE key = 'timezone_offset') AS start_iso,
  CASE WHEN d.window_end IS NOT NULL
       THEN d.draw_date || 'T' || d.window_end || ':00' || (SELECT value FROM settings WHERE key = 'timezone_offset')
       ELSE strftime('%Y-%m-%dT%H:%M:%S', datetime(d.draw_date || ' ' || COALESCE(d.window_start, '08:00') || ':00',
            '+' || (SELECT value FROM settings WHERE key = 'default_draw_minutes') || ' minutes'))
            || (SELECT value FROM settings WHERE key = 'timezone_offset')
  END AS end_iso,
  'shift-draw-' || d.draw_id                 AS idempotency_key,
  d.zensched_shift_id,
  NULL                                       AS schedule_notes
FROM draws d
JOIN patients p ON p.patient_id = d.patient_id AND p.is_active = 1
JOIN clients cl ON cl.client_id = d.client_id AND cl.is_active = 1
JOIN addresses a ON a.address_id = d.address_id AND a.is_active = 1
LEFT JOIN phlebs ph ON ph.phleb_id = d.phleb_id
WHERE d.schedule_id IS NULL
  AND d.status IN ('scheduled', 'checked_in')
  AND d.draw_date BETWEEN date('now', 'localtime') AND date('now', 'localtime', '+6 days')
ORDER BY 1, 18;

-- Today's board: standing slots still due today plus every draws row dated
-- today (one-offs, completed, missed). Cancelled rows are omitted.
CREATE VIEW IF NOT EXISTS draws_today AS
SELECT
  draw_date,
  schedule_id,
  draw_id,
  source,
  patient_id,
  patient_name,
  patient_code,
  client_id,
  client_name,
  address_id,
  address,
  city,
  zensched_label,
  zensched_location_id,
  zensched_event_id,
  event_valid_until,
  event_needs_roll,
  window_start,
  window_end,
  worker_id,
  phleb_name,
  unassigned,
  start_iso,
  end_iso,
  idempotency_key,
  zensched_shift_id
FROM draws_due_this_week
WHERE draw_date = date('now', 'localtime')
UNION ALL
SELECT
  d.draw_date,
  d.schedule_id,
  d.draw_id,
  CASE WHEN d.schedule_id IS NULL THEN 'one_off' ELSE 'recurring' END AS source,
  p.patient_id,
  p.patient_name,
  p.patient_code,
  cl.client_id,
  cl.client_name,
  a.address_id,
  a.address,
  a.city,
  a.zensched_label,
  a.zensched_location_id,
  a.zensched_event_id,
  a.event_valid_until,
  CASE WHEN a.event_valid_until IS NULL OR a.event_valid_until < d.draw_date THEN 1 ELSE 0 END AS event_needs_roll,
  d.window_start,
  d.window_end,
  COALESCE(d.zensched_worker_id, ph.zensched_worker_id) AS worker_id,
  ph.phleb_name,
  CASE WHEN COALESCE(d.zensched_worker_id, ph.zensched_worker_id) IS NULL THEN 1 ELSE 0 END AS unassigned,
  COALESCE(d.scheduled_start, d.draw_date || 'T' || COALESCE(d.window_start, '08:00') || ':00' || (SELECT value FROM settings WHERE key = 'timezone_offset')) AS start_iso,
  COALESCE(d.scheduled_end, d.draw_date || 'T' || COALESCE(d.window_end, d.window_start, '08:30') || ':00' || (SELECT value FROM settings WHERE key = 'timezone_offset')) AS end_iso,
  'shift-draw-' || d.draw_id AS idempotency_key,
  d.zensched_shift_id
FROM draws d
JOIN patients p ON p.patient_id = d.patient_id
JOIN clients cl ON cl.client_id = d.client_id
JOIN addresses a ON a.address_id = d.address_id
LEFT JOIN phlebs ph ON ph.phleb_id = d.phleb_id
WHERE d.draw_date = date('now', 'localtime')
  AND d.status IN ('completed', 'missed')
ORDER BY 18;

-- Addresses whose current ZenSched event expires within 14 days (or has none)
-- and that still have an active standing schedule or an upcoming booked draw.
CREATE VIEW IF NOT EXISTS event_needs_roll AS
SELECT
  a.address_id,
  p.patient_id,
  p.patient_code,
  p.patient_name,
  a.zensched_label,
  a.address,
  a.city,
  a.zensched_location_id,
  a.zensched_event_id,
  a.event_valid_until
FROM addresses a
JOIN patients p ON p.patient_id = a.patient_id AND p.is_active = 1
WHERE a.is_active = 1
  AND (a.event_valid_until IS NULL OR a.event_valid_until <= date('now', 'localtime', '+14 days'))
  AND (
       EXISTS (SELECT 1 FROM draw_schedule s WHERE s.address_id = a.address_id AND s.is_active = 1)
    OR EXISTS (SELECT 1 FROM draws d WHERE d.address_id = a.address_id
                 AND d.status IN ('scheduled', 'checked_in')
                 AND d.draw_date >= date('now', 'localtime'))
  )
ORDER BY a.event_valid_until;

-- Draws in the last 14 days flagged hematoma / faint / other, or recorded as
-- Unable. Lead with these in every summary. Local view; may show names.
CREATE VIEW IF NOT EXISTS open_complications AS
SELECT
  d.draw_id,
  d.draw_date,
  d.draw_outcome,
  d.complications,
  d.complication_notes,
  d.unable_reason,
  p.patient_id,
  p.patient_name,
  p.patient_code,
  p.phone,
  cl.client_id,
  cl.client_name,
  ph.phleb_name,
  d.tube_count,
  d.zensched_shift_id,
  d.report_dc_id
FROM draws d
JOIN patients p ON p.patient_id = d.patient_id
JOIN clients cl ON cl.client_id = d.client_id
LEFT JOIN phlebs ph ON ph.phleb_id = d.phleb_id
WHERE (d.complications <> 'none' OR d.draw_outcome = 'unable')
  AND d.draw_date >= date('now', 'localtime', '-14 days')
ORDER BY CASE d.draw_outcome WHEN 'unable' THEN 0 ELSE 1 END, d.draw_date DESC;

-- Completed draws not yet invoiced, grouped by CLIENT (the lab). Patient
-- names are deliberately omitted; patient_codes is the only identifier.
CREATE VIEW IF NOT EXISTS draws_to_invoice AS
SELECT
  cl.client_id,
  cl.client_name,
  cl.client_type,
  cl.contact_email,
  cl.contact_phone,
  cl.payment_terms_days,
  COUNT(d.draw_id)                           AS draw_count,
  SUM(d.bill_amount)                         AS total_amount,
  group_concat(DISTINCT p.patient_code)      AS patient_codes,
  MIN(d.draw_date)                           AS first_draw_date,
  MAX(d.draw_date)                           AS last_draw_date
FROM draws d
JOIN clients cl ON cl.client_id = d.client_id
JOIN patients p ON p.patient_id = d.patient_id
WHERE d.invoiced = 0
  AND d.status = 'completed'
GROUP BY cl.client_id
ORDER BY cl.client_name;

-- Hours worked that have not yet been included in a payroll run, per phleb.
-- pay_rate is the snapshot on the draw (falls back to the roster / default).
CREATE VIEW IF NOT EXISTS payroll_hours_unpaid AS
SELECT
  ph.phleb_id,
  ph.phleb_name,
  ph.zensched_worker_id,
  COUNT(d.draw_id)                           AS draw_count,
  SUM(d.hours)                               AS total_hours,
  SUM(round(d.hours * COALESCE(d.pay_rate, ph.pay_rate,
        (SELECT CAST(value AS REAL) FROM settings WHERE key = 'default_pay_rate')), 2)) AS gross_pay,
  MIN(d.draw_date)                           AS first_draw_date,
  MAX(d.draw_date)                           AS last_draw_date
FROM draws d
JOIN phlebs ph ON ph.phleb_id = d.phleb_id
WHERE d.paid_out = 0
  AND d.status = 'completed'
GROUP BY ph.phleb_id
ORDER BY ph.phleb_name;

-- Unpaid lab invoices, oldest first. No patient names.
CREATE VIEW IF NOT EXISTS invoices_outstanding AS
SELECT
  i.invoice_id,
  i.invoice_number,
  cl.client_id,
  cl.client_name,
  cl.client_type,
  cl.contact_email,
  i.invoice_date,
  i.due_date,
  i.draw_count,
  i.total_amount,
  i.sent_date,
  CASE WHEN i.due_date < date('now', 'localtime') THEN 1 ELSE 0 END AS overdue
FROM invoices i
JOIN clients cl ON cl.client_id = i.client_id
WHERE i.paid = 0
ORDER BY i.due_date;
