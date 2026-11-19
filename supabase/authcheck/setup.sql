-- One company for the sign-in check; its first Admin gets access by signing up with this e-mail.
select public.create_company('Acme Industries', 'acme', 'Asia/Kolkata', 'admin@acme.test', 'Asha Admin');
insert into public.locations (company_id, name, lat, lng, radius_m)
  select id, 'Andheri HQ', 19.1136, 72.8697, 150 from public.companies where slug = 'acme';
