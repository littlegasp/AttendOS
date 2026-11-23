-- AttendOS development preflight (G5): SYNTHETIC test data only — two invented companies, invented people and devices.
-- DEVELOPMENT PROJECT ONLY: run through `python3 dev_sql.py dev_seed_synthetic.sql` (guarded) after 0001–0013 and
-- verify_hosted.sql show ok. It stops unless the database carries the development marker for the given reference.
--
-- Nothing here is real: names say "Test", e-mails use the reserved domain attendos-dev.example (it cannot receive
-- mail), device serials start TEST-DEV-, every date is in 2030 or later in the files the tests generate. No
-- employee mapping is created (owner boundary). No real X2008 export is ever uploaded here (owner decision D2).
--
-- Logins: the owner creates one Auth user per e-mail below (Authentication → Users → Add user → "Auto confirm user"),
-- with a long random password kept in the local logins file (see README). 0005 links each login to its record by the
-- confirmed work e-mail. Roles used by the tests:
--   A admin, A admin2, A hr, A manager, A employee  — company "dev-alpha"
--   B admin, B hr, B employee                         — company "dev-beta"
do $$ begin
  if to_regclass('attendos_dev.environment_marker') is null
     or not exists (select 1 from attendos_dev.environment_marker where environment = 'development'
                    and project_ref = current_setting('attendos.dev_ref', true)) then
    raise exception 'STOP: not the AttendOS development project (run through dev_sql.py)';
  end if;
  if exists (select 1 from public.companies where slug in ('dev-alpha', 'dev-beta')) then
    raise exception 'STOP: the synthetic companies already exist (the seed runs once; to start again, delete and recreate the development project)';
  end if;
  if exists (select 1 from public.companies) then
    raise exception 'STOP: this development database already holds other companies; the seed only runs on an otherwise empty project';
  end if;
end $$;

select public.create_company('TEST Dev Alpha (synthetic)', 'dev-alpha', 'Asia/Kolkata', 'a.admin@attendos-dev.example', 'Test Admin Alpha') as alpha;
select public.create_company('TEST Dev Beta (synthetic)', 'dev-beta', 'Asia/Kolkata', 'b.admin@attendos-dev.example', 'Test Admin Beta') as beta;

insert into public.employees (company_id, full_name, email, role, emp_code)
select c.id, v.full_name, v.email, v.role, v.emp_code
  from (values
    ('dev-alpha', 'Test Admin Alpha Two', 'a.admin2@attendos-dev.example', 'admin', 'TA002'),
    ('dev-alpha', 'Test HR Alpha', 'a.hr@attendos-dev.example', 'hr', 'TA003'),
    ('dev-alpha', 'Test Manager Alpha', 'a.manager@attendos-dev.example', 'manager', 'TA004'),
    ('dev-alpha', 'Test Employee Alpha', 'a.employee@attendos-dev.example', 'employee', 'TA005'),
    ('dev-alpha', 'Test Person Alpha 06', 'a.person06@attendos-dev.example', 'employee', 'TA006'),
    ('dev-alpha', 'Test Person Alpha 07', 'a.person07@attendos-dev.example', 'employee', 'TA007'),
    ('dev-beta', 'Test HR Beta', 'b.hr@attendos-dev.example', 'hr', 'TB003'),
    ('dev-beta', 'Test Employee Beta', 'b.employee@attendos-dev.example', 'employee', 'TB005')) v(slug, full_name, email, role, emp_code)
  join public.companies c on c.slug = v.slug;

-- Devices (file import needs no Sync Agent). Alpha: an X2008 (the only model the DAT profile may be assigned to), an
-- eSSL of another model and a ZKTeco reader — both must be refused. Beta: its own X2008, for isolation checks.
-- No format is assigned here: the tests assign it as an Admin through the API, as the screen does.
insert into public.biometric_devices (company_id, name, manufacturer, model, serial_number, firmware_version, integration_method, timezone)
select c.id, v.name, v.manufacturer, v.model, v.serial, v.firmware, 'file_import', 'Asia/Kolkata'
  from (values
    ('dev-alpha', 'TEST X2008 Alpha (synthetic)', 'essl', 'X2008', 'TEST-DEV-X2008-A', '8.0.4.2-20180530'),
    ('dev-alpha', 'TEST eSSL K21 Alpha (synthetic)', 'essl', 'K21', 'TEST-DEV-K21-A', null),
    ('dev-alpha', 'TEST ZKTeco Alpha (synthetic)', 'zkteco', 'MB160', 'TEST-DEV-ZK-A', null),
    ('dev-beta', 'TEST X2008 Beta (synthetic)', 'essl', 'X2008', 'TEST-DEV-X2008-B', null)) v(slug, name, manufacturer, model, serial, firmware)
  join public.companies c on c.slug = v.slug;

-- What was created (all synthetic); no mapping exists
select c.slug, e.full_name, e.email, e.role, e.emp_code, e.user_id is not null as login_linked
  from public.employees e join public.companies c on c.id = e.company_id order by c.slug, e.role, e.email;
select c.slug, d.name, d.manufacturer, d.model from public.biometric_devices d join public.companies c on c.id = d.company_id order by 1, 2;
select count(*) as employee_mappings from public.biometric_employee_mappings;
