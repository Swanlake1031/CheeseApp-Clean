"""Run rollback-only SQL tests and real-artifact parity on an explicit local fixture DB.

Never accepts a network URL or a production container. The optional draft refresh
updates only the two not-yet-deployed scoring functions on this fixture database.
Supautils is omitted ONLY for this connection to avoid its known EXECUTE-denial
SIGSEGV (supabase/supautils#214). Actual authenticated/anon grants stay unchanged.
"""
import argparse
import json
import re
import subprocess
from pathlib import Path

from .classifier import load_model, predict
from .schema import load_dataset, load_embedding

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parent
DOCKER = '/Applications/Docker.app/Contents/Resources/bin/docker'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--container', required=True)
    parser.add_argument('--refresh-draft-scoring', action='store_true')
    args = parser.parse_args()
    if not re.fullmatch(r'supabase_db_cheese-rec-v2-db\.[A-Za-z0-9]+', args.container):
        parser.error('Only the explicitly named isolated V2 fixture database is allowed')
    command = [DOCKER, 'exec', '-i', '-e', 'PGOPTIONS=-c session_preload_libraries=',
               args.container, 'sh', '-c',
               'PGPASSWORD="$POSTGRES_PASSWORD" psql -X -qAt -U supabase_admin -d postgres -v ON_ERROR_STOP=1']

    def sql(source):
        result = subprocess.run(command, input=source, text=True, capture_output=True)
        if result.returncode:
            raise RuntimeError(result.stderr.strip())
        if re.search(r'^not ok\b', result.stdout, re.M):
            print(result.stdout)
            raise RuntimeError('SQL regression has failed assertions')
        return result.stdout

    if args.refresh_draft_scoring:
        migration = (REPO/'Supabase/migrations/20260910024900_recommendation_v2_cross_school.sql').read_text()
        definitions = []
        for name in ['recommendation_private.score_post', 'public.backfill_cross_school_scores']:
            match = re.search(r'CREATE FUNCTION ' + re.escape(name) + r'\(.*?\n\$\$;', migration, re.S)
            if not match:
                raise ValueError('Missing draft function: ' + name)
            definitions.append(match[0].replace('CREATE FUNCTION', 'CREATE OR REPLACE FUNCTION', 1))
        sql('BEGIN;\n' + '\n'.join(definitions) + '\nCOMMIT;')
        print('Refreshed only draft scoring functions in isolated fixture database.')

    suite = REPO/'Supabase/tests/database/20260910024900_recommendation_v2_cross_school.test.sql'
    print(sql(suite.read_text()))
    v1_suite = REPO/'Supabase/tests/database/190_recommendation_v1.test.sql'
    print(sql(v1_suite.read_text().replace(
        'BEGIN;', 'BEGIN; CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions; '
        'SET LOCAL search_path = public, extensions, pg_temp;', 1)))

    # Exercise the actual frozen teacher artifact on every cached dataset/sanity input.
    folder = ROOT/'cross_school'
    model = load_model(folder/'artifacts/cross-school-logistic-v1-teacher-v01.json')
    rows = load_dataset(folder/'data/teacher_v01.jsonl') + load_dataset(folder/'data/sanity_v1.jsonl')
    expected = []
    statements = ['BEGIN;', 'CREATE TEMP TABLE parity_model(a jsonb);',
                  "INSERT INTO parity_model VALUES ('" + json.dumps(model).replace("'", "''") + "'::jsonb);"]
    for index, row in enumerate(rows):
        vector = load_embedding(row, folder/'cache')
        expected.append(predict(model, vector))
        statements.append(f"SELECT {index}, recommendation_private.predict(a, '{json.dumps(vector)}'::extensions.vector) FROM parity_model;")
    statements.append('ROLLBACK;')
    lines = sql('\n'.join(statements)).strip().splitlines()
    if len(lines) != len(rows):
        raise AssertionError('Unexpected parity result count')
    max_error = 0.0
    for index, line in enumerate(lines):
        ordinal, value = line.split('|')
        if int(ordinal) != index or not value:
            raise AssertionError('Missing/reordered SQL probability')
        actual = float(value)
        max_error = max(max_error, abs(actual-expected[index]))
        if abs(actual-expected[index]) > 1e-12 or (actual >= model['threshold']) != (expected[index] >= model['threshold']):
            raise AssertionError('Python/SQL classifier mismatch')
    print(f'PASS: {len(rows)} actual-embedding Python/SQL predictions and gate decisions; maximum error {max_error:.3g}')
    state = sql('SELECT gate_enabled,scoring_enabled,shadow_enabled FROM public.cross_school_configuration; '
                "SELECT count(*) FROM public.posts WHERE id::text LIKE '29000000-0000-4000-8000-%';")
    if state.strip() != 'f|f|f\n0':
        raise AssertionError('Fixture cleanup/default flags unexpected: ' + state)
    print('PASS: fixtures rolled back; all V2 switches remain off.')


if __name__ == '__main__':
    main()
