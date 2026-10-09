-- Owner-managed branches and explicit approval for new POS installations.
-- Custom POS sessions are the application's current auth model; every RPC
-- validates the opaque session token and the operator's business membership.

create table if not exists public.pos_location_pairing_codes (
  code_hash text primary key,
  location_id uuid not null references public.locations(id) on delete cascade,
  business_id uuid not null references public.businesses(id) on delete cascade,
  created_by uuid not null references public.profiles(id),
  expires_at timestamptz not null,
  used_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.pos_terminal_access_requests (
  id uuid primary key default gen_random_uuid(),
  request_token_hash text not null unique,
  device_id text not null,
  device_name text not null,
  location_id uuid not null references public.locations(id) on delete cascade,
  business_id uuid not null references public.businesses(id) on delete cascade,
  status text not null default 'PENDING' check (status in ('PENDING','APPROVED','REJECTED','EXPIRED')),
  requested_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by uuid references public.profiles(id)
);

create table if not exists public.pos_terminal_devices (
  device_id text primary key,
  device_name text not null,
  location_id uuid not null references public.locations(id) on delete cascade,
  business_id uuid not null references public.businesses(id) on delete cascade,
  approved_by uuid not null references public.profiles(id),
  approved_at timestamptz not null default now(),
  active boolean not null default true
);

alter table public.pos_location_pairing_codes enable row level security;
alter table public.pos_terminal_access_requests enable row level security;
alter table public.pos_terminal_devices enable row level security;
revoke all on public.pos_location_pairing_codes, public.pos_terminal_access_requests, public.pos_terminal_devices from anon, authenticated;

create or replace function public.pos_admin_create_location(p_token text,p_location_id uuid,p_name text)
returns table(location_id uuid,location_name text) language plpgsql security definer
set search_path = public, extensions, pg_temp as $$
declare v_operator record; v_business_id uuid; v_location_id uuid;
begin
 select * into v_operator from public.pos_operator_for_token(p_token,p_location_id);
 if v_operator.user_id is null or v_operator.user_role<>'ADMIN' then raise exception 'Solo el administrador del negocio puede crear sucursales'; end if;
 select l.business_id into v_business_id from public.locations l where l.id=p_location_id and l.active;
 if v_business_id is null or not exists(select 1 from public.business_memberships bm where bm.business_id=v_business_id and bm.user_id=v_operator.user_id and bm.active and bm.role='ADMIN') then raise exception 'No tiene autorización para administrar este negocio'; end if;
 if length(trim(coalesce(p_name,''))) not between 2 and 80 then raise exception 'El nombre debe tener entre 2 y 80 caracteres'; end if;
 if exists(select 1 from public.locations l where l.business_id=v_business_id and lower(trim(l.name))=lower(trim(p_name)) and l.active) then raise exception 'Ya existe una sucursal con ese nombre'; end if;
 insert into public.locations(business_id,name,active) values(v_business_id,trim(p_name),true) returning id into v_location_id;
 insert into public.location_memberships(location_id,profile_id,role,active) values(v_location_id,v_operator.user_id,'ADMIN',true) on conflict(location_id,profile_id) do update set role='ADMIN',active=true;
 return query select v_location_id,trim(p_name);
end $$;

create or replace function public.pos_admin_list_business_locations(p_token text,p_location_id uuid)
returns table(location_id uuid,location_name text,active boolean,created_at timestamptz) language plpgsql security definer stable
set search_path = public, extensions, pg_temp as $$
declare v_operator record; v_business_id uuid;
begin
 select * into v_operator from public.pos_operator_for_token(p_token,p_location_id);
 select l.business_id into v_business_id from public.locations l where l.id=p_location_id and l.active;
 if v_operator.user_id is null or v_operator.user_role<>'ADMIN' or not exists(select 1 from public.business_memberships bm where bm.business_id=v_business_id and bm.user_id=v_operator.user_id and bm.active and bm.role='ADMIN') then raise exception 'No tiene autorización para administrar este negocio'; end if;
 return query select l.id,l.name,l.active,l.created_at from public.locations l where l.business_id=v_business_id order by l.created_at;
end $$;

create or replace function public.pos_admin_create_location_pairing_code(p_token text,p_location_id uuid,p_target_location_id uuid)
returns table(pairing_code text,expires_at timestamptz) language plpgsql security definer
set search_path = public, extensions, pg_temp as $$
declare v_operator record; v_business_id uuid; v_code text; v_exp timestamptz;
begin
 select * into v_operator from public.pos_operator_for_token(p_token,p_location_id);
 select l.business_id into v_business_id from public.locations l where l.id=p_location_id and l.active;
 if v_operator.user_id is null or v_operator.user_role<>'ADMIN' or not exists(select 1 from public.business_memberships bm where bm.business_id=v_business_id and bm.user_id=v_operator.user_id and bm.active and bm.role='ADMIN') then raise exception 'No tiene autorización para administrar este negocio'; end if;
 if not exists(select 1 from public.locations where id=p_target_location_id and business_id=v_business_id and active) then raise exception 'Sucursal inválida'; end if;
 v_code:=upper(encode(extensions.gen_random_bytes(10),'hex')); v_exp:=now()+interval '24 hours';
 insert into public.pos_location_pairing_codes(code_hash,location_id,business_id,created_by,expires_at) values(encode(extensions.digest(v_code,'sha256'),'hex'),p_target_location_id,v_business_id,v_operator.user_id,v_exp);
 return query select v_code,v_exp;
end $$;

create or replace function public.pos_request_terminal_access(p_pairing_code text,p_device_id text,p_device_name text)
returns table(request_id uuid,request_token text,location_name text) language plpgsql security definer
set search_path = public, extensions, pg_temp as $$
declare v_code public.pos_location_pairing_codes%rowtype; v_request_id uuid; v_request_token text;
begin
 if length(trim(coalesce(p_device_id,''))) not between 16 and 80 or length(trim(coalesce(p_device_name,''))) not between 2 and 80 then raise exception 'Datos de equipo inválidos'; end if;
 select * into v_code from public.pos_location_pairing_codes c where c.code_hash=encode(extensions.digest(upper(trim(coalesce(p_pairing_code,''))),'sha256'),'hex') and c.used_at is null and c.expires_at>now() for update;
 if v_code.code_hash is null then raise exception 'Código inválido, vencido o ya utilizado'; end if;
 if exists(select 1 from public.pos_terminal_devices d where d.device_id=trim(p_device_id) and d.active) then raise exception 'Este equipo ya está vinculado'; end if;
 v_request_token:=encode(extensions.gen_random_bytes(32),'hex');
 insert into public.pos_terminal_access_requests(request_token_hash,device_id,device_name,location_id,business_id) values(encode(extensions.digest(v_request_token,'sha256'),'hex'),trim(p_device_id),trim(p_device_name),v_code.location_id,v_code.business_id) returning id into v_request_id;
 update public.pos_location_pairing_codes set used_at=now() where code_hash=v_code.code_hash;
 return query select v_request_id,v_request_token,l.name from public.locations l where l.id=v_code.location_id;
end $$;

create or replace function public.pos_login_terminal_session(p_username text,p_password text,p_location_id uuid,p_device_id text)
returns table(session_token text,user_id uuid,username text,display_name text,user_role text,location_name text,expires_at timestamptz)
language plpgsql security definer
set search_path = public, extensions, pg_temp as $$
declare v_profile public.profiles%rowtype; v_role text; v_location_name text; v_token text;
begin
 select l.name into v_location_name from public.locations l where l.id=p_location_id and l.active;
 if v_location_name is null then raise exception 'Sucursal no encontrada o inactiva'; end if;
 if not exists(select 1 from public.pos_terminal_devices d where d.device_id=trim(coalesce(p_device_id,'')) and d.location_id=p_location_id and d.active) then
   raise exception 'Este POS aún no está aprobado. Solicita acceso al administrador desde la pantalla inicial.';
 end if;
 select p.* into v_profile from public.location_memberships lm join public.profiles p on p.id=lm.profile_id
 where lm.location_id=p_location_id and lm.active and p.active
   and lower(trim(p.username))=lower(trim(p_username))
   and p.password_hash=encode(extensions.digest(coalesce(p_password,'')||'_cabana_pos_salt','sha256'),'hex') limit 1;
 if v_profile.id is null then raise exception 'Usuario o contraseña incorrectos'; end if;
 select lm.role into v_role from public.location_memberships lm where lm.location_id=p_location_id and lm.profile_id=v_profile.id and lm.active;
 v_token:=encode(extensions.gen_random_bytes(32),'hex');
 insert into public.pos_operator_sessions(token_hash,profile_id,location_id,expires_at)
 values(encode(extensions.digest(v_token,'sha256'),'hex'),v_profile.id,p_location_id,now()+interval '12 hours');
 return query select v_token,v_profile.id,v_profile.username,coalesce(nullif(v_profile.display_name,''),v_profile.username),v_role,v_location_name,now()+interval '12 hours';
end $$;

create or replace function public.pos_terminal_access_status(p_request_token text)
returns table(request_status text,location_id uuid,location_name text) language plpgsql security definer stable
set search_path = public, extensions, pg_temp as $$
begin
 return query select case when r.status='PENDING' and r.requested_at<now()-interval '24 hours' then 'EXPIRED' else r.status end,
  case when r.status='APPROVED' then r.location_id else null end,case when r.status='APPROVED' then l.name else null end
 from public.pos_terminal_access_requests r join public.locations l on l.id=r.location_id
 where r.request_token_hash=encode(extensions.digest(coalesce(p_request_token,''),'sha256'),'hex') and r.requested_at>now()-interval '48 hours';
end $$;

create or replace function public.pos_admin_list_terminal_requests(p_token text,p_location_id uuid)
returns table(request_id uuid,device_name text,location_id uuid,location_name text,requested_at timestamptz) language plpgsql security definer stable
set search_path = public, extensions, pg_temp as $$
declare v_operator record; v_business_id uuid;
begin
 select * into v_operator from public.pos_operator_for_token(p_token,p_location_id);
 select l.business_id into v_business_id from public.locations l where l.id=p_location_id and l.active;
 if v_operator.user_id is null or v_operator.user_role<>'ADMIN' or not exists(select 1 from public.business_memberships bm where bm.business_id=v_business_id and bm.user_id=v_operator.user_id and bm.active and bm.role='ADMIN') then raise exception 'No tiene autorización para aprobar equipos'; end if;
 return query select r.id,r.device_name,r.location_id,l.name,r.requested_at from public.pos_terminal_access_requests r join public.locations l on l.id=r.location_id where r.business_id=v_business_id and r.status='PENDING' and r.requested_at>now()-interval '24 hours' order by r.requested_at;
end $$;

create or replace function public.pos_admin_decide_terminal_request(p_token text,p_location_id uuid,p_request_id uuid,p_approve boolean)
returns text language plpgsql security definer
set search_path = public, extensions, pg_temp as $$
declare v_operator record; v_business_id uuid; v_request public.pos_terminal_access_requests%rowtype;
begin
 select * into v_operator from public.pos_operator_for_token(p_token,p_location_id);
 select l.business_id into v_business_id from public.locations l where l.id=p_location_id and l.active;
 if v_operator.user_id is null or v_operator.user_role<>'ADMIN' or not exists(select 1 from public.business_memberships bm where bm.business_id=v_business_id and bm.user_id=v_operator.user_id and bm.active and bm.role='ADMIN') then raise exception 'No tiene autorización para aprobar equipos'; end if;
 select * into v_request from public.pos_terminal_access_requests r where r.id=p_request_id and r.business_id=v_business_id and r.status='PENDING' for update;
 if v_request.id is null or v_request.requested_at<now()-interval '24 hours' then raise exception 'La solicitud ya venció o fue procesada'; end if;
 if p_approve then
  if exists(select 1 from public.pos_terminal_devices d where d.device_id=v_request.device_id and d.active and d.location_id<>v_request.location_id) then
    raise exception 'Este equipo ya está autorizado en otra sucursal; primero debe revocarse allí';
  end if;
  insert into public.pos_terminal_devices(device_id,device_name,location_id,business_id,approved_by) values(v_request.device_id,v_request.device_name,v_request.location_id,v_business_id,v_operator.user_id)
  on conflict(device_id) do update set device_name=excluded.device_name,location_id=excluded.location_id,business_id=excluded.business_id,approved_by=excluded.approved_by,approved_at=now(),active=true;
  update public.pos_terminal_access_requests set status='APPROVED',decided_at=now(),decided_by=v_operator.user_id where id=v_request.id;
  return 'APPROVED';
 end if;
 update public.pos_terminal_access_requests set status='REJECTED',decided_at=now(),decided_by=v_operator.user_id where id=v_request.id;
 return 'REJECTED';
end $$;

revoke all on function public.pos_admin_create_location(text,uuid,text) from public,anon,authenticated;
revoke all on function public.pos_admin_list_business_locations(text,uuid) from public,anon,authenticated;
revoke all on function public.pos_admin_create_location_pairing_code(text,uuid,uuid) from public,anon,authenticated;
revoke all on function public.pos_request_terminal_access(text,text,text) from public,anon,authenticated;
revoke all on function public.pos_login_terminal_session(text,text,uuid,text) from public,anon,authenticated;
revoke all on function public.pos_terminal_access_status(text) from public,anon,authenticated;
revoke all on function public.pos_admin_list_terminal_requests(text,uuid) from public,anon,authenticated;
revoke all on function public.pos_admin_decide_terminal_request(text,uuid,uuid,boolean) from public,anon,authenticated;
grant execute on function public.pos_admin_create_location(text,uuid,text) to anon,authenticated;
grant execute on function public.pos_admin_list_business_locations(text,uuid) to anon,authenticated;
grant execute on function public.pos_admin_create_location_pairing_code(text,uuid,uuid) to anon,authenticated;
grant execute on function public.pos_request_terminal_access(text,text,text) to anon,authenticated;
grant execute on function public.pos_login_terminal_session(text,text,uuid,text) to anon,authenticated;
grant execute on function public.pos_terminal_access_status(text) to anon,authenticated;
grant execute on function public.pos_admin_list_terminal_requests(text,uuid) to anon,authenticated;
grant execute on function public.pos_admin_decide_terminal_request(text,uuid,uuid,boolean) to anon,authenticated;

-- Retire the old terminal-registration lookup endpoint.
revoke all on function public.register_pos_location(text,uuid) from public,anon,authenticated;
