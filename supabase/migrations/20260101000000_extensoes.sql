-- T0.3: extensoes base do ambiente (o schema de dominio vem na T1.1).
create extension if not exists postgis with schema extensions;
create extension if not exists pg_cron;
