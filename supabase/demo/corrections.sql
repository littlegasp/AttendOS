-- created through the real request function as each person
set role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000000d4',false);
select request_correction(local_today(my_company())-3,'missing_out',null,at_local(my_company(), local_today(my_company())-3,'18:40'),'Phone battery died before I could check out');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000000e2',false);
select request_correction(local_today(my_company())-3,'missing_in',at_local(my_company(), local_today(my_company())-3,'07:05'),at_local(my_company(), local_today(my_company())-3,'16:00'),'Gate network was down at the plant');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000000f6',false);
select request_correction(local_today(my_company())-2,'other',at_local(my_company(), local_today(my_company())-2,'09:35'),at_local(my_company(), local_today(my_company())-2,'18:30'),'Client visit in Powai all day, forgot to check in');
reset role;
