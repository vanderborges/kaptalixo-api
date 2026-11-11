begin;
select plan(2);
select has_extension('postgis', 'extensao postgis instalada');
select has_extension('pg_cron', 'extensao pg_cron instalada');
select * from finish();
rollback;
