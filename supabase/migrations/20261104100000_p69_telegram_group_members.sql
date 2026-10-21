-- Decision 423 (OWNER, 21 October 2026): a registered Telegram group serves every member who writes in it.
-- The owner uses one group from more than one Telegram account, so the group, not each Telegram id, is the trust
-- boundary. A member with a link of their own acts with that link's permissions; anyone else acts as the link that
-- registered the group (so the per-entry limit, the permission checks and the period guards of that link still run).
-- Unregistered chats are still ignored. Same signature and return shape as before, so grants stay in place.
create or replace function public.telegram_identify(p_telegram_user bigint, p_chat bigint, p_thread bigint default null)
returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  l public.telegram_links%rowtype;
  c public.telegram_chats%rowtype;
  v_topic uuid;
  v_is_private boolean := false;
  v_has_link boolean;
  v_access jsonb;
  v_claims text := current_setting('request.jwt.claims', true);
  v_sub text := current_setting('request.jwt.claim.sub', true);
begin
  select * into l from public.telegram_links where telegram_user_id = p_telegram_user and status = 'active';
  v_has_link := found;
  if not (v_has_link and p_chat = l.telegram_chat_id) then
    -- A registered group serves every member who writes in it (decision 423, owner request: the group is the owner's
    -- own, used from more than one Telegram account). A member who linked an account of their own acts with that
    -- link and its permissions; anyone else acts as the link that registered the group. Unregistered chats: nobody.
    select * into c from public.telegram_chats where chat_id = p_chat;
    if not found then
      return null;
    end if;
    if not v_has_link then
      select * into l from public.telegram_links where id = c.link_id and status = 'active';
      if not found then
        return null;
      end if;
    end if;
    select t.entity_id into v_topic from public.telegram_chat_topics t
    where t.chat_id = p_chat and t.thread_id = coalesce(p_thread, 0);
    v_topic := coalesce(v_topic, c.default_entity_id);
  else
    v_is_private := true;
  end if;
  if not exists (select 1 from public.profiles p where p.id = l.user_id and p.is_active) then
    return null;
  end if;
  perform app_private.telegram_act_as(l.id);
  v_access := public.my_access();
  perform app_private.telegram_restore_claims(v_claims, v_sub);
  if not coalesce((v_access ->> 'active')::boolean, false) then
    return null;
  end if;
  return jsonb_build_object(
    'link_id', l.id,
    'user_id', l.user_id,
    'display_name', v_access ->> 'display_name',
    'username', l.telegram_username,
    'is_private', v_is_private,
    'max_entry_amount', l.max_entry_amount::text,
    'language', l.language,
    'report_daily', l.report_daily,
    'report_weekly', l.report_weekly,
    'report_monthly', l.report_monthly,
    'default_entity_id', l.default_entity_id,
    'chat_entity_id', v_topic,
    'memberships', coalesce((
      select jsonb_agg(jsonb_build_object(
        'entity_id', m ->> 'entity_id', 'entity_code', m ->> 'entity_code', 'entity_type', m ->> 'entity_type',
        'entity_name', m ->> 'entity_name',
        'can_create', (m -> 'permissions') ? 'bills.create',
        'can_confirm', (m -> 'permissions') ? 'bills.pay',
        'can_view', (m -> 'permissions') ? 'bills.view'))
      from jsonb_array_elements(coalesce(v_access -> 'memberships', '[]'::jsonb)) m), '[]'::jsonb));
end
$$;
