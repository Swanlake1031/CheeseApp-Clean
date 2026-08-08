-- 054_fix_handle_new_user_school_id.sql
-- Ensure signup trigger can create profiles after profiles.school_id became NOT NULL.

BEGIN;

-- Re-seed schools/campuses in case data was manually deleted.
INSERT INTO public.schools (name, city, region, default_radius_km, active)
VALUES
  ('University of Toronto', 'Toronto', 'ON', 25, TRUE),
  ('York University', 'Toronto', 'ON', 25, TRUE),
  ('Toronto Metropolitan University', 'Toronto', 'ON', 25, TRUE),
  ('OCAD University', 'Toronto', 'ON', 25, TRUE),
  ('Ontario Tech University', 'Oshawa', 'ON', 25, TRUE),
  ('McMaster University', 'Hamilton', 'ON', 25, TRUE),
  ('Redeemer University', 'Hamilton', 'ON', 25, TRUE),
  ('University of Guelph-Humber', 'Toronto', 'ON', 25, TRUE),
  ('Seneca Polytechnic', 'Toronto', 'ON', 25, TRUE),
  ('Humber Polytechnic', 'Toronto', 'ON', 25, TRUE),
  ('George Brown College', 'Toronto', 'ON', 25, TRUE),
  ('Centennial College', 'Toronto', 'ON', 25, TRUE),
  ('Sheridan College', 'Oakville', 'ON', 25, TRUE),
  ('Durham College', 'Oshawa', 'ON', 25, TRUE),
  ('Mohawk College', 'Hamilton', 'ON', 25, TRUE)
ON CONFLICT (name) DO UPDATE
SET
  city = EXCLUDED.city,
  region = EXCLUDED.region,
  default_radius_km = EXCLUDED.default_radius_km,
  active = EXCLUDED.active,
  updated_at = NOW();

WITH s AS (
  SELECT id, name FROM public.schools
)
INSERT INTO public.school_campuses (school_id, name, geo, is_default)
SELECT
  s.id,
  seed.campus_name,
  extensions.ST_SetSRID(extensions.ST_MakePoint(seed.lng, seed.lat), 4326)::extensions.geography,
  TRUE
FROM s
JOIN (
  VALUES
    ('University of Toronto', 'St. George Campus', -79.3957::double precision, 43.6629::double precision),
    ('York University', 'Keele Campus', -79.5027, 43.7735),
    ('Toronto Metropolitan University', 'Downtown Campus', -79.3781, 43.6577),
    ('OCAD University', 'Main Campus', -79.3923, 43.6532),
    ('Ontario Tech University', 'North Oshawa Campus', -78.8958, 43.9455),
    ('McMaster University', 'Main Campus', -79.9192, 43.2609),
    ('Redeemer University', 'Ancaster Campus', -79.9556, 43.2294),
    ('University of Guelph-Humber', 'Humber North Campus', -79.6060, 43.7286),
    ('Seneca Polytechnic', 'Newnham Campus', -79.3495, 43.7957),
    ('Humber Polytechnic', 'North Campus', -79.6060, 43.7286),
    ('George Brown College', 'St James Campus', -79.3685, 43.6518),
    ('Centennial College', 'Progress Campus', -79.2272, 43.7855),
    ('Sheridan College', 'Trafalgar Campus', -79.6990, 43.4696),
    ('Durham College', 'Oshawa Campus', -78.8967, 43.9458),
    ('Mohawk College', 'Fennell Campus', -79.8854, 43.2386)
) AS seed(school_name, campus_name, lng, lat)
  ON seed.school_name = s.name
WHERE NOT EXISTS (
  SELECT 1
  FROM public.school_campuses c
  WHERE c.school_id = s.id
    AND c.is_default = TRUE
);

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_requested_school TEXT;
  v_school_id UUID;
  v_school_name TEXT;
BEGIN
  v_requested_school := NULLIF(btrim(COALESCE(NEW.raw_user_meta_data->>'university', '')), '');

  IF v_requested_school IS NOT NULL THEN
    SELECT s.id, s.name
    INTO v_school_id, v_school_name
    FROM public.schools s
    WHERE lower(s.name) = lower(v_requested_school)
    LIMIT 1;
  END IF;

  IF v_school_id IS NULL THEN
    SELECT s.id, s.name
    INTO v_school_id, v_school_name
    FROM public.schools s
    WHERE s.active = TRUE
    ORDER BY
      CASE WHEN s.name = 'McMaster University' THEN 0 ELSE 1 END,
      s.name
    LIMIT 1;
  END IF;

  IF v_school_id IS NULL THEN
    INSERT INTO public.schools (name, city, region, default_radius_km, active)
    VALUES ('McMaster University', 'Hamilton', 'ON', 25, TRUE)
    ON CONFLICT (name) DO UPDATE
      SET active = TRUE
    RETURNING id, name
    INTO v_school_id, v_school_name;
  END IF;

  IF v_school_id IS NULL THEN
    RAISE EXCEPTION 'cannot create profile: missing school seed data';
  END IF;

  INSERT INTO public.profiles (id, email, university, school_id)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(v_requested_school, v_school_name),
    v_school_id
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_user();

NOTIFY pgrst, 'reload schema';

COMMIT;
