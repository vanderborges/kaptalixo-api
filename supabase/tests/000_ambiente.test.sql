begin;
select plan(2);
select has_extension('extensions', 'postgis', 'extensao postgis instalada no schema extensions');
select has_extension('pg_cron', 'extensao pg_cron instalada');
select * from finish();
rollback;
