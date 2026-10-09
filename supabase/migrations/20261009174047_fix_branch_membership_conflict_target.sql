-- RETURNS TABLE exposes location_id as a PL/pgSQL variable; name the unique
-- constraint explicitly to avoid its collision with the insert column.
create or replace function public.pos_admin_create_location(p_token text,p_location_id uuid,p_name text)
returns table(location_id uuid,location_name text)
language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare v_operator record; v_business_id uuid; v_location_id uuid;
begin
 select * into v_operator from public.pos_operator_for_token(p_token,p_location_id);
 if v_operator.user_id is null or v_operator.user_role<>'ADMIN' then raise exception 'Solo el administrador del negocio puede crear sucursales'; end if;
 select l.business_id into v_business_id from public.locations l where l.id=p_location_id and l.active;
 if v_business_id is null or not exists(select 1 from public.business_memberships bm where bm.business_id=v_business_id and bm.user_id=v_operator.user_id and bm.active and bm.role='ADMIN') then raise exception 'No tiene autorización para administrar este negocio'; end if;
 if length(trim(coalesce(p_name,''))) not between 2 and 80 then raise exception 'El nombre debe tener entre 2 y 80 caracteres'; end if;
 if exists(select 1 from public.locations l where l.business_id=v_business_id and lower(trim(l.name))=lower(trim(p_name)) and l.active) then raise exception 'Ya existe una sucursal con ese nombre'; end if;
 insert into public.locations(business_id,name,active) values(v_business_id,trim(p_name),true) returning id into v_location_id;
 insert into public.location_memberships(location_id,profile_id,role,active) values(v_location_id,v_operator.user_id,'ADMIN',true)
   on conflict on constraint location_memberships_location_id_profile_id_key do update set role='ADMIN',active=true;
 return query select v_location_id,trim(p_name);
end $$;
