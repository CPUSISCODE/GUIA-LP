-- Funções do painel. Ao contrário dos auxiliares em private, estas PRECISAM ser
-- chamáveis por authenticated — é assim que o painel funciona. A autorização
-- está dentro de cada uma, na primeira linha. O advisor vai apontá-las como
-- security definer executáveis; é intencional e está documentado no README.

create or replace function public.listar_usuarios()
returns table (
  id uuid,
  email text,
  nome text,
  empresa text,
  aprovado boolean,
  bloqueado boolean,
  limite_dispositivos integer,
  observacao text,
  admin boolean,
  criado_em timestamptz,
  email_confirmado boolean,
  ultimo_login timestamptz,
  total_dispositivos bigint,
  dispositivos_sobre_limite bigint,
  total_acessos bigint,
  ultimo_acesso timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.e_admin() then
    raise exception 'Apenas administradores podem listar usuários.' using errcode = '42501';
  end if;

  return query
  select
    u.id,
    u.email::text,
    p.nome,
    p.empresa,
    coalesce(p.aprovado, false),
    coalesce(p.bloqueado, false),
    coalesce(p.limite_dispositivos, 2),
    p.observacao,
    (a.id is not null) as admin,
    u.created_at,
    (u.email_confirmed_at is not null) as email_confirmado,
    u.last_sign_in_at,
    coalesce(d.total, 0) as total_dispositivos,
    greatest(coalesce(d.total, 0) - coalesce(p.limite_dispositivos, 2), 0) as dispositivos_sobre_limite,
    coalesce(ac.total, 0) as total_acessos,
    ac.ultimo
  from auth.users u
  left join public.profiles p on p.id = u.id
  left join public.admins a on a.id = u.id
  left join (
    select dd.user_id, count(*) as total from public.dispositivos dd group by dd.user_id
  ) d on d.user_id = u.id
  left join (
    select aa.user_id, count(*) as total, max(aa.quando) as ultimo
    from public.acessos aa group by aa.user_id
  ) ac on ac.user_id = u.id
  order by u.created_at;
end;
$$;

-- Promove pelo e-mail e já deixa aprovado e desbloqueado — senão o novo admin
-- fica sem acesso à base que ele deveria administrar.
create or replace function public.promover_admin(p_email text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if not private.e_admin() then
    raise exception 'Apenas administradores podem promover outro administrador.' using errcode = '42501';
  end if;

  select u.id into v_id from auth.users u
  where lower(u.email) = lower(trim(p_email));

  if v_id is null then
    raise exception 'Não existe usuário com o e-mail %.', p_email using errcode = 'P0002';
  end if;

  insert into public.admins (id, criado_por)
  values (v_id, (select auth.uid()))
  on conflict (id) do nothing;

  update public.profiles
     set aprovado = true, bloqueado = false
   where id = v_id;

  return v_id;
end;
$$;

-- Recusa remover o último admin: sem isso o sistema fica sem ninguém que
-- possa administrar, e não há como voltar atrás pelo painel.
create or replace function public.rebaixar_admin(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_total integer;
begin
  if not private.e_admin() then
    raise exception 'Apenas administradores podem rebaixar um administrador.' using errcode = '42501';
  end if;

  if not exists (select 1 from public.admins a where a.id = p_id) then
    raise exception 'Este usuário não é administrador.' using errcode = 'P0002';
  end if;

  select count(*) into v_total from public.admins;
  if v_total <= 1 then
    raise exception 'Não é possível remover o último administrador do sistema.' using errcode = '42501';
  end if;

  delete from public.admins where id = p_id;
end;
$$;
