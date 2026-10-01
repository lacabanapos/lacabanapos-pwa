-- location_memberships stores the linked profile in profile_id.
-- Keep membership helper functions aligned with the live schema.
CREATE OR REPLACE FUNCTION private.sync_location_memberships_from_business_membership()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'private'
AS $function$
begin
  if tg_op = 'UPDATE' and (
    new.role is distinct from old.role
    or new.active is distinct from old.active
  ) then
    if new.role in ('OWNER', 'ADMIN') then
      delete from public.location_memberships
      where profile_id = new.user_id
        and location_id in (
          select id from public.locations where business_id = new.business_id
        );
    else
      update public.location_memberships lm
      set role = new.role, active = new.active
      where lm.profile_id = new.user_id
        and lm.location_id in (
          select id from public.locations where business_id = new.business_id
        );
    end if;
  end if;
  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION private.has_location_role(target_location_id uuid, allowed_roles text[])
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'private'
AS $function$
  select (select private.is_platform_superadmin())
    or exists (
      select 1
      from public.locations l
      join public.business_memberships bm
        on bm.business_id = l.business_id
       and bm.user_id = (select auth.uid())
       and bm.active
       and bm.role in ('OWNER', 'ADMIN')
      where l.id = target_location_id
        and l.active
    )
    or exists (
      select 1
      from public.location_memberships lm
      join public.locations l on l.id = lm.location_id and l.active
      join public.business_memberships bm
        on bm.business_id = l.business_id
       and bm.user_id = lm.profile_id
       and bm.active
      where lm.location_id = target_location_id
        and lm.profile_id = (select auth.uid())
        and lm.active
        and lm.role = any(allowed_roles)
        and bm.role = lm.role
    );
$function$;
