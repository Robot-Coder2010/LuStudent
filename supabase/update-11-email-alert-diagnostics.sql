-- Apply after update-10-student-leadership-hub.sql.
-- Adds an admin-only RPC for reading the asynchronous Apps Script response.

alter table public.notify_config
  add column if not exists last_response text;

create or replace function public.check_email_alert_status()
returns jsonb
language plpgsql security definer set search_path = public, net as $$
declare
  cfg public.notify_config;
  response_status int;
  response_content text;
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;

  select * into cfg from public.notify_config where id = 1;
  if not found then
    return jsonb_build_object('pending', false, 'message', 'Email alerts are not configured.');
  end if;

  if cfg.last_request_id is null then
    return jsonb_build_object(
      'pending', false,
      'status', cfg.last_status,
      'body', cfg.last_response,
      'message', 'No email request is waiting for a response.'
    );
  end if;

  select r.status_code, r.content
    into response_status, response_content
    from net._http_response r
   where r.id = cfg.last_request_id;

  if not found then
    return jsonb_build_object('pending', true, 'message', 'The email request is still processing.');
  end if;

  if not cfg.last_request_test
     and response_status between 200 and 299
     and response_content ~ '"ok"[[:space:]]*:[[:space:]]*true' then
    update public.submissions
       set notified_at = now()
     where status = 'pending'
       and notified_at is null
       and created_at <= cfg.last_batch_created_before;
  end if;

  update public.notify_config
     set last_status = response_status,
         last_response = left(response_content, 2000),
         last_request_id = null,
         last_batch_created_before = null,
         last_request_test = false
   where id = 1;

  return jsonb_build_object(
    'pending', false,
    'status', response_status,
    'body', left(response_content, 2000)
  );
end $$;

revoke all on function public.check_email_alert_status() from public, anon, authenticated;
grant execute on function public.check_email_alert_status() to authenticated;

notify pgrst, 'reload schema';
