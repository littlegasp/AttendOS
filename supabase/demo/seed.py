import datetime
import random
random.seed(7)
U=lambda c: f"00000000-0000-0000-0000-0000000000{c}"
CA="cccccccc-0000-0000-0000-00000000000a"  # Acme Industries (Mumbai)
people=[ # code, name, role, dept, office, manager, designation, joined, phone
("a1","Rohan Mehta","admin","Accounts","L1",None,"Finance Manager","2019-04-01","+91 98200 10001"),
("b2","Hema Kulkarni","hr","HR","L1",None,"HR Manager","2020-06-15","+91 98200 10002"),
("c3","Sana Shaikh","manager","Sales","L1",None,"Sales Manager","2021-01-11","+91 98200 10003"),
("d4","Esha Patil","employee","Sales","L1","c3","Sales Executive","2023-08-01","+91 98200 10004"),
("e5","Rahul Menon","employee","Sales","L2","c3","Sales Executive","2022-02-14",None),
("f6","Kiran Rao","employee","Sales","L1","c3","Sales Executive","2024-03-04",None),
("a7","Meera Iyer","employee","Sales","L1","c3","Key Account Manager","2021-09-20",None),
("b8","Vikram Desai","employee","Operations",None,None,"Logistics Coordinator","2022-11-07",None),
("c9","Arjun Nair","employee","Operations","L2",None,"Plant Supervisor","2020-01-06",None),
("d1","Pooja Joshi","employee","Accounts","L1","a1","Accountant","2023-05-22",None),
("e2","Farhan Khan","employee","Operations","L2",None,"Machine Operator","2024-07-01",None),
("f3","Neha Gupta","employee","HR","L1","b2","HR Executive","2025-02-03",None),
]
L={"L1":"11111111-1111-1111-1111-111111111111","L2":"22222222-2222-2222-2222-222222222222","L3":"33333333-3333-3333-3333-333333333333"}
S={"GEN":"aaaaaaaa-0000-0000-0000-000000000001","NIGHT":"aaaaaaaa-0000-0000-0000-000000000002","EARLY":"aaaaaaaa-0000-0000-0000-000000000003"}
D={"Sales":"dddddddd-0000-0000-0000-000000000001","Operations":"dddddddd-0000-0000-0000-000000000002","Accounts":"dddddddd-0000-0000-0000-000000000003","HR":"dddddddd-0000-0000-0000-000000000004"}
TODAY=f"local_today('{CA}')"
def AT(n,hhmm): return f"at_local('{CA}', {TODAY}-{n}, '{hhmm}')"
out=[]
w=out.append
w(f"insert into companies (id,name,slug,timezone,max_accuracy_m) values ('{CA}','Acme Industries','acme','Asia/Kolkata',100);")
w(f"insert into locations (id,company_id,name,address,lat,lng,radius_m,active) values ('{L['L1']}','{CA}','Andheri HQ','Saki Vihar Rd, Andheri East, Mumbai',19.1136,72.8697,150,true),('{L['L2']}','{CA}','Pune Plant','Chakan MIDC Phase II, Pune',18.7603,73.8630,250,true),('{L['L3']}','{CA}','Thane Warehouse','Wagle Estate, Thane',19.1960,72.9560,200,false);")
w(f"insert into shifts (id,company_id,name,start_time,end_time,break_minutes,grace_minutes) values ('{S['GEN']}','{CA}','General','09:30','18:30',60,15),('{S['NIGHT']}','{CA}','Night','22:00','06:00',45,10),('{S['EARLY']}','{CA}','Early','07:00','16:00',60,10);")
w(f"update companies set default_shift_id='{S['GEN']}' where id='{CA}';")
for d,code,desc in [("Sales","SAL","Field and key-account sales"),("Operations","OPS","Plant, logistics and dispatch"),("Accounts","ACC","Billing, payables and payroll inputs"),("HR","HR","People operations")]:
    w(f"insert into departments (id,company_id,name,code,description) values ('{D[d]}','{CA}','{d}','{code}','{desc}');")
for g in sorted(set(p[6] for p in people)):
    w(f"insert into designations (company_id,name) values ('{CA}','{g}');")
for i,(code,name,role,dept,off,mgr,des,joined,phone) in enumerate(people):
    w(f"insert into employees (id,company_id,full_name,email,role,department_id,home_location_id,emp_code,designation_id,joining_date,phone,employment_status) values ('{U(code)}','{CA}','{name}','{name.split()[0].lower()}@acme.in','{role}','{D[dept]}',{'NULL' if not off else repr(L[off])},'E{101+i:04d}',(select id from designations where company_id='{CA}' and name='{des}'),'{joined}',{'NULL' if not phone else repr(phone)},'{'probation' if joined>='2025-01-01' else 'confirmed'}');")
for code,name,role,dept,off,mgr,des,joined,phone in people:
    if mgr: w(f"update employees set manager_id='{U(mgr)}' where id='{U(code)}';")
w(f"update departments set head_id='{U('c3')}' where id='{D['Sales']}'; update departments set head_id='{U('c9')}' where id='{D['Operations']}'; update departments set head_id='{U('a1')}' where id='{D['Accounts']}'; update departments set head_id='{U('b2')}' where id='{D['HR']}';")
# a new joiner without a login yet, and someone who left
w(f"insert into employees (id,company_id,full_name,email,role,department_id,home_location_id,emp_code,designation_id,joining_date,employment_status,manager_id) values ('{U('b5')}','{CA}','Tanvi Shah','tanvi@acme.in','employee','{D['Sales']}','{L['L1']}','E0113',(select id from designations where company_id='{CA}' and name='Sales Executive'),{TODAY}+3,'probation','{U('c3')}');")
w(f"insert into employees (id,company_id,full_name,email,role,department_id,home_location_id,emp_code,designation_id,joining_date,employment_status,exit_date,active) values ('{U('c6')}','{CA}','Imran Sheikh','imran@acme.in','employee','{D['Operations']}','{L['L2']}','E0098',(select id from designations where company_id='{CA}' and name='Machine Operator'),'2022-03-01','exited','2026-10-31',false);")
# logins (confirmed e-mail) → linked automatically
for code,name,*_ in people:
    w(f"insert into auth.users (id,email) values ('{U(code)}','{name.split()[0].lower()}@acme.in');")
# patterns
for wd in [1,2,3,4,5]:
    w(f"insert into roster_pattern values ('{U('b8')}',{wd},'remote',NULL);")
for wd in [1,2,3,4,5,6]:
    w(f"insert into shift_pattern values ('{U('c9')}',{wd},'{S['NIGHT']}');")
for wd in [1,2,3,4,5,6]:
    w(f"insert into roster_pattern values ('{U('c9')}',{wd},'office','{L['L2']}');")
w(f"update employees set default_shift_id='{S['EARLY']}' where id='{U('e2')}';")
w(f"insert into roster_pattern values ('{U('d4')}',3,'remote',NULL);")  # Esha WFH Wednesdays
w(f"insert into remote_exceptions (employee_id,start_date,end_date,reason) values ('{U('a7')}',{TODAY}-3,{TODAY}+8,'Working from Bengaluru for client rollout');")
w(f"insert into roster_day (employee_id,day,work_mode,location_id,note) values ('{U('e5')}',{TODAY}+1,'office','{L['L1']}','Quarterly review at HQ');")
w(f"insert into shift_day (employee_id,day,shift_id) values ('{U('f6')}',{TODAY}+2,'{S['EARLY']}');")
w(f"insert into holidays (company_id,day,name) values ('{CA}','2026-11-24','Guru Nanak Jayanti'),('{CA}','2026-12-25','Christmas'),('{CA}','2027-01-26','Republic Day'),('{CA}','2026-11-09','Diwali (Lakshmi Puja)');")
w(f"insert into holidays (company_id,day,name,location_id) values ('{CA}','2026-12-01','Plant maintenance day','{L['L2']}');")
# events
ev=[]
def E(code,n,kind,hhmm,mode='office',loc=None,dist=None,acc=None,wd_n=None,ver=None):
    wd=n if wd_n is None else wd_n
    ver = (mode=='office' and kind in('in','out')) if ver is None else ver
    ev.append(f"('{U(code)}','{kind}',{AT(n,hhmm)},'{mode}',{('%r'%L[loc]) if loc else 'NULL'},{dist if dist is not None else 'NULL'},{acc if acc is not None else 'NULL'},{str(ver).lower()},{TODAY}-{wd})")
# past 13 days for general-shift office people
gen_people=["a1","b2","c3","d4","e5","f6","a7","d1","f3"]
for n in range(1,19):
    for code in gen_people:
        p=[x for x in people if x[0]==code][0]
        off=p[4] or "L1"
        # weekend handled by SQL? we need weekday: compute in python using a reference: skip; use SQL filter later
        r=random.random()
        if (code=="f6" and n in (1,2,6)) or (code=="d1" and n==1): continue  # absences
        if code=="d4" and n==3:
            E(code,n,'in','09:36','office',off,42,18); continue  # missing checkout
        mode='remote' if code=="a7" and n<=3 else 'office'
        if code=="d4" and (datetime.date(2026,11,19)-datetime.timedelta(days=n)).weekday()==2: mode='remote'
        tin = f"09:{random.choice([12,18,22,25,28,31,34,38,44])}" if r>0.18 else f"09:{random.choice([47,52,58])}" if r>0.05 else "10:12"
        tout = random.choice(["18:20","18:35","18:41","18:50","19:05","19:40","20:10"]) if random.random()>0.12 else random.choice(["16:45","17:10"])
        loc = off if mode=='office' else None
        E(code,n,'in',tin,mode,loc,random.randint(8,120) if loc else None,random.randint(9,70))
        if random.random()>0.3:
            E(code,n,'break_start',random.choice(['13:05','13:12','13:20']),mode,ver=False)
            E(code,n,'break_end',random.choice(['13:50','13:58','14:04']),mode,ver=False)
        E(code,n,'out',tout,mode,loc,random.randint(8,120) if loc else None,random.randint(9,70))
    # Vikram remote
    E("b8",n,'in',f"09:{random.choice([20,26,33])}",'remote'); E("b8",n,'out',random.choice(["18:30","18:45"]),'remote')
    # Farhan early shift at Pune
    if n!=3:
        E("e2",n,'in',f"07:0{random.choice([2,5,8])}",'office','L2',random.randint(20,200),random.randint(12,60)); E("e2",n,'out',"16:05",'office','L2',60,25)
    # Arjun night: in on day n at 21:5x, out next morning (day n-1 calendar) with work_date n
    E("c9",n,'in',f"21:5{random.choice([2,6,8])}",'office','L2',90,30)
    ev.append(f"('{U('c9')}','out',{AT(n-1,'06:0'+str(random.choice([3,8])))},'office','{L['L2']}',85,28,true,{TODAY}-{n})")
# today (n=0) — mid morning
today=[("b2","09:15",None),("c3","09:28",None),("d4","09:51",None),("e5","09:20",("09:55",None)),("a7","09:35","remote"),("d1","09:25",None),("f3","09:31",None),("a1","09:58",None)]
for code,tin,extra in today:
    p=[x for x in people if x[0]==code][0]
    mode='remote' if extra=="remote" else 'office'
    off=p[4] or "L1"
    E(code,0,'in',tin,mode,off if mode=='office' else None,random.randint(10,90) if mode=='office' else None,random.randint(10,60))
    if isinstance(extra,tuple):
        E(code,0,'break_start',extra[0],mode,ver=False)
E("b8",0,'in',"09:28",'remote')
E("e2",0,'in',"07:04",'office','L2',140,22)
w("insert into attendance_events (employee_id,kind,at,work_mode,location_id,distance_m,accuracy_m,verified,work_date) values\n"+",\n".join(ev)+";")
# drop events on days off (weekends / holidays) for everyone except night shift Saturday; done in SQL
w(f"""delete from attendance_events e where e.work_date < {TODAY} and (select work_mode from plan_for(e.employee_id, e.work_date)) = 'off';""")
w("delete from attendance_events where at > now();  -- never show future check-ins whatever time the demo is built")
# refusals
w(f"""insert into attendance_attempts (employee_id,kind,at,reason,accuracy_m,distance_m) values
('{U('f6')}','in',now()-interval '3 hours','outside_area',24,1850),
('{U('d4')}','in',{AT(0,'09:47')},'accuracy_low',162,null),
('{U('e2')}','in',{AT(2,'07:01')},'outside_area',35,640),
('{U('f6')}','in',{AT(1,'09:40')},'location_required',null,null);""")
# a second company that must never see Acme's data
w("select create_company('Beta Logistics','beta','Europe/London','bina@beta.co','Bina Owner');")
w("insert into locations (company_id,name,address,lat,lng,radius_m) select id,'Beta HQ','Westminster, London',51.5007,-0.1246,200 from companies where slug='beta';")
w("insert into departments (company_id,name) select id,'Fleet' from companies where slug='beta';")
w("insert into employees (company_id,full_name,email,emp_code,department_id) select c.id,'Ben Staff','ben@beta.co','B001',d.id from companies c join departments d on d.company_id=c.id where c.slug='beta';")
w("insert into auth.users (id,email) values ('00000000-0000-0000-0000-0000000000f9','bina@beta.co'),('00000000-0000-0000-0000-0000000000f8','ben@beta.co');")
open("seed.sql","w").write("\n".join(out)+"\n")
