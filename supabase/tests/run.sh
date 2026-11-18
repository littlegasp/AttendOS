#!/bin/sh
# Runs the migration and the access tests on a throwaway local Postgres database.
# Usage: PGHOST=/tmp/pg PGPORT=5433 PGUSER=postgres sh supabase/tests/run.sh
set -e
cd "$(dirname "$0")"
dropdb --if-exists attendos_test && createdb attendos_test
psql -q -v ON_ERROR_STOP=1 -d attendos_test -f auth_stub.sql -f ../migrations/0001_attendance_core.sql -f attendance_test.sql
