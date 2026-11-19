-- Synthetic company for performance measurement only (never on a real database).
-- psql -v n=500 -v days=60 -f generate.sql
select create_company('Perf Industries', 'perf', 'Asia/Kolkata', 'admin@perf.test', 'Perf Admin');
select set_config('perf.c', (select id::text from companies where slug = 'perf'), false);
insert into locations (company_id, name, lat, lng, radius_m)
  select current_setting('perf.c')::uuid, 'Office ' || i, 19.0 + i * 0.05, 72.8 + i * 0.05, 200 from generate_series(1, 3) i;
insert into departments (company_id, name) select current_setting('perf.c')::uuid, 'Dept ' || i from generate_series(1, 8) i;
insert into shifts (company_id, name, start_time, end_time) values (current_setting('perf.c')::uuid, 'General', '09:30', '18:30');
update companies set default_shift_id = (select id from shifts where company_id = current_setting('perf.c')::uuid) where id = current_setting('perf.c')::uuid;
insert into employees (company_id, full_name, email, department_id, home_location_id, joining_date, manager_id)
  select current_setting('perf.c')::uuid, 'Person ' || i, 'p' || i || '@perf.test',
         (select id from departments where company_id = current_setting('perf.c')::uuid order by name offset (i % 8) limit 1),
         (select id from locations where company_id = current_setting('perf.c')::uuid order by name offset (i % 3) limit 1),
         current_date - 400, null
    from generate_series(1, :n) i;
-- Every 10th person manages the next nine
update employees e set role = 'manager' where e.company_id = current_setting('perf.c')::uuid and e.email ~ '^p[0-9]*0@';
update employees e set manager_id = m.id from employees m
 where e.company_id = current_setting('perf.c')::uuid and m.company_id = e.company_id and e.role = 'employee'
   and m.email = 'p' || ((substring(e.email from 'p([0-9]+)@')::int / 10) * 10 + 10) || '@perf.test';
insert into auth.users (id, email) select gen_random_uuid(), 'hr@perf.test';
insert into employees (company_id, full_name, email, role) values (current_setting('perf.c')::uuid, 'Perf HR', 'hr2@perf.test', 'hr');
-- Attendance: 90% of working days, in 09:20–09:59, out 18:00–19:30
insert into attendance_events (employee_id, kind, at, work_mode, location_id, distance_m, accuracy_m, verified, work_date)
  select e.id, k.kind,
         at_local(e.company_id, d::date, case when k.kind = 'in' then time '09:20' + (random() * interval '40 min') else time '18:00' + (random() * interval '90 min') end),
         'office', e.home_location_id, (random() * 120)::int, (10 + random() * 40)::int, true, d::date
    from employees e
    cross join generate_series(current_date - :days, current_date - 1, interval '1 day') d
    cross join (values ('in'), ('out')) k(kind)
   where e.company_id = current_setting('perf.c')::uuid and extract(dow from d) <> 0 and random() < 0.9
     and hashtext(e.id::text || d::text) % 10 <> 0;
analyze;
select count(*) as people from employees where company_id = current_setting('perf.c')::uuid;
select count(*) as events from attendance_events;
