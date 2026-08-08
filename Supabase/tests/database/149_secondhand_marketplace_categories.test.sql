BEGIN;

SELECT plan(5);

SELECT is(
  public.normalize_secondhand_category('furniture'),
  'home_appliances',
  'legacy furniture maps to the merged home category'
);
SELECT is(
  public.normalize_secondhand_category('appliances'),
  'home_appliances',
  'legacy appliances maps to the merged home category'
);
SELECT is(
  public.normalize_secondhand_category('clothing'),
  'fashion_accessories',
  'legacy clothing maps to fashion and accessories'
);
SELECT is(
  public.normalize_secondhand_category('academic'),
  'books_academic',
  'legacy academic maps to books and academics'
);
SELECT is(
  public.normalize_secondhand_category('pet_supplies'),
  'pet_supplies',
  'the new pet supplies category remains stable'
);

SELECT * FROM finish();
ROLLBACK;
