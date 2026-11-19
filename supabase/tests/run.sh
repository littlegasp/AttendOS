#!/bin/sh
# Runs the migration and the access tests on a throwaway local Postgres database.
# Usage: PGHOST=/tmp/pg PGPORT=5433 PGUSER=postgres sh supabase/tests/run.sh
set -e
cd "$(dirname "$0")"
dropdb --if-exists attendos_test && createdb attendos_test
psql -q -v ON_ERROR_STOP=1 -d attendos_test -f auth_stub.sql -f ../migrations/0001_attendance_core.sql -f attendance_test.sql -f ../migrations/0002_refinement.sql -f refinement_test.sql -f ../migrations/0003_multi_tenant.sql -f tenancy_test.sql -f ../migrations/0004_employees.sql -f employees_test.sql -f ../migrations/0005_verification.sql -f verification_test.sql -f ../migrations/0006_leave_register_reports.sql -f leave_reports_test.sql -f ../migrations/0007_invitations.sql -f invitations_test.sql -f ../migrations/0008_hardening.sql -f security_matrix_test.sql
