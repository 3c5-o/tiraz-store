alter table public.integration_credentials add column if not exists worker_key text not null default gen_random_uuid()::text;
create or replace function public.claim_outbox() returns setof public.notification_outbox language plpgsql security definer set search_path=public as $$
begin return query with ready as(select id from notification_outbox where ((state in ('pending','failed') and next_attempt<=now()) or (state='processing' and next_attempt<now()-interval '5 minutes')) and attempts<12 order by created_at limit 20 for update skip locked) update notification_outbox o set state='processing',attempts=o.attempts+1,next_attempt=now() from ready where o.id=ready.id returning o.*;end$$;
revoke all on function public.claim_outbox() from public,anon,authenticated;
grant execute on function public.claim_outbox() to service_role;
create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;
select cron.schedule('tiraz-outbox-v110','* * * * *',$cron$
select net.http_post(url:='https://pivvmyvbgjdhphlsdttw.supabase.co/functions/v1/process-outbox',headers:=jsonb_build_object('Content-Type','application/json','x-worker-key',(select worker_key from public.integration_credentials where id=true)),body:='{}'::jsonb,timeout_milliseconds:=120000);
$cron$);
