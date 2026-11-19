"use client";

import { supabase } from "@/lib/supabase";
import { must, useLoad } from "@/lib/use-load";

export interface Lookups {
  departments: { id: string; name: string; active: boolean }[];
  designations: { id: string; name: string; active: boolean }[];
  locations: { id: string; name: string; active: boolean }[];
  shifts: { id: string; name: string; start_time: string; end_time: string; active: boolean }[];
  people: { id: string; emp_code: string | null; full_name: string; role: string; department_id: string | null; active: boolean }[];
}

/**
 * Pick-lists for the employee screens, all read live from the company's own data
 * (people pickers come from people_directory(), which the database limits to the company).
 */
export function useLookups(key = "lookups") {
  return useLoad<Lookups>(async () => {
    const sb = supabase();
    const [departments, designations, locations, shifts, people] = await Promise.all([
      sb.from("departments").select("id, name, active").order("name").then(must<Lookups["departments"]>),
      sb.from("designations").select("id, name, active").order("name").then(must<Lookups["designations"]>),
      sb.from("locations").select("id, name, active").order("name").then(must<Lookups["locations"]>),
      sb.from("shifts").select("id, name, start_time, end_time, active").order("start_time").then(must<Lookups["shifts"]>),
      sb.rpc("people_directory").then(must<Lookups["people"]>),
    ]);
    return { departments, designations, locations, shifts, people };
  }, key);
}

export const EMP_SELECT =
  "id, emp_code, full_name, email, phone, role, active, user_id, department_id, designation_id, manager_id, home_location_id, default_shift_id, joining_date, employment_status, exit_date, created_at, " +
  "department:departments!employees_department_id_fkey(name), designation:designations(name), office:locations(name), manager:manager_id(full_name)";
