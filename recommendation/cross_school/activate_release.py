"""Explicit, single-transaction activation of the reviewed V2 artifact.

Only targets the user's confirmed CheeseApp-Clean linked project. No PDF,
course, post, embedding or user data is deleted. Without --activate, no command
is executed. Run only after deployment and regression verification.
"""
import argparse
import json
import subprocess
from pathlib import Path

from .classifier import load_model

REPO = Path(__file__).resolve().parents[2]
PROJECT = 'zeuivahkowbxmfzsnagt'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--activate', action='store_true')
    args = parser.parse_args()
    if (REPO/'Supabase/.temp/project-ref').read_text().strip() != PROJECT:
        raise ValueError('Linked project differs from the explicitly approved deployment target')
    model = load_model(REPO/'recommendation/cross_school/artifacts/cross-school-logistic-v1-teacher-v01.json')
    if model['version'] != 'v1-teacher-v01' or model['threshold'] != 0.55:
        raise ValueError('Unexpected release artifact')
    if not args.activate:
        print('Ready: v1-teacher-v01, threshold 0.55; no changes made. --activate is required.')
        return
    artifact = json.dumps(model).replace("'", "''")
    threshold_version = model['threshold_version'].replace("'", "''")
    query = f"""
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';
SELECT set_config('request.jwt.claim.role','service_role',true);
SELECT set_config('request.jwt.claims','{{"role":"service_role"}}',true);
INSERT INTO public.cross_school_models(version,artifact,approved_for_filtering)
VALUES ('v1-teacher-v01','{artifact}'::jsonb,true)
ON CONFLICT(version) DO NOTHING;
DO $check$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.cross_school_models
   WHERE version='v1-teacher-v01' AND artifact='{artifact}'::jsonb) THEN
  RAISE EXCEPTION 'Registered artifact differs; refusing activation';
 END IF;
END $check$;
-- Runtime approval records the user's explicit direct-release instruction.
-- Artifact metadata remains unchanged: synthetic results are not production validation.
UPDATE public.cross_school_models SET approved_for_filtering=true WHERE version='v1-teacher-v01';
UPDATE public.cross_school_configuration SET model_version='v1-teacher-v01',
 scoring_enabled=true,shadow_enabled=false,gate_enabled=false,rollout_percentage=0,
 threshold=0.55,threshold_version='{threshold_version}' WHERE singleton;
SELECT public.backfill_cross_school_scores(500);
DO $check$ BEGIN
 IF EXISTS(SELECT 1 FROM public.forum_posts f JOIN public.posts p ON p.id=f.id
   WHERE p.status='active' AND NOT p.is_private AND (f.origin_school_id IS NULL OR NOT EXISTS(
     SELECT 1 FROM public.post_embeddings e JOIN public.cross_school_scores s
       ON s.post_id=e.post_id AND s.model_version='v1-teacher-v01'
       AND s.embedding_version=e.embedding_version AND s.embedding_revision=e.cross_school_revision
       AND s.input_hash=e.input_hash AND s.probability IS NOT NULL
     WHERE e.post_id=f.id AND e.status='ready' AND e.model='gemini-embedding-2'
       AND e.embedding_version='cheese-semantic-v1' AND e.input_format_version=1))) THEN
   RAISE EXCEPTION 'Incomplete score/origin coverage; activation rolled back';
 END IF;
END $check$;
UPDATE public.recommendation_configuration SET rollout_percentage=100 WHERE singleton;
UPDATE public.cross_school_configuration SET gate_enabled=true,rollout_percentage=100 WHERE singleton;
COMMIT;
SELECT jsonb_build_object('model_version',model_version,'threshold',threshold,
 'gate_enabled',gate_enabled,'scoring_enabled',scoring_enabled,'shadow_enabled',shadow_enabled,
 'rollout_percentage',rollout_percentage,'revision',revision) AS release
FROM public.cross_school_configuration WHERE singleton;
"""
    result = subprocess.run(['supabase', 'db', 'query', '--linked', '--file', '/dev/stdin'],
                            input=query, text=True, capture_output=True, cwd=REPO)
    if result.returncode:
        # Do not dump submitted SQL/model or automatically retry ambiguous writes.
        print('Activation command failed. Independently inspect configuration before any retry.')
        print(result.stderr[-2500:])
        raise SystemExit(result.returncode)
    print(result.stdout)


if __name__ == '__main__':
    main()
