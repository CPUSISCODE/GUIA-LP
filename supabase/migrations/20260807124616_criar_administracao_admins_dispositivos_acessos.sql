-- Administração do GUIA-LP: quem é admin, quem está liberado, de quais aparelhos.
--
-- Idempotente e correspondente ao que já está aplicado no projeto FAROL-GUIA-LP.
-- Os nomes de policy, função e trigger são propositalmente os do GUIA-LP e NÃO
-- os do GUIA-SN — são dois projetos Supabase distintos.

-- ---------------------------------------------------------------------------
-- Schema private: auxiliares usados DENTRO das policies.
-- Em public eles ganhariam rota em /rest/v1/rpc/... e o advisor acusaria.
-- O PostgREST não expõe este schema.
-- ---------------------------------------------------------------------------
create schema if not exists private;
grant usage on schema private to authenticated;

-- ---------------------------------------------------------------------------
-- Quem é administrador.
-- A flag NÃO fica em profiles de propósito: lá o usuário tem policy de update
-- no próprio registro, então uma coluna "admin" seria auto-atribuível e
-- qualquer um viraria admin sozinho. Esta tabela não tem nenhuma policy de
-- escrita para o cliente — entra e sai dela só por promover_admin/rebaixar_admin.
-- ---------------------------------------------------------------------------
create table if not exists public.admins (
  id uuid primary key references auth.users (id) on delete cascade,
  criado_em timestamptz not null default now(),
  criado_por uuid references auth.users (id) on delete set null
);

comment on table public.admins is 'Administradores do painel. Sem policy de escrita: alterações só pelas funções promover_admin e rebaixar_admin.';

alter table public.admins enable row level security;

-- O usuário só enxerga a própria linha. É isso que o frontend usa para decidir
-- se mostra a aba Administração: quem não é admin recebe zero linhas.
drop policy if exists admins_select_proprio on public.admins;
create policy admins_select_proprio
  on public.admins
  for select
  to authenticated
  using ( (select auth.uid()) = id );

create or replace function private.e_admin(p_id uuid default null)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.admins a
    where a.id = coalesce(p_id, (select auth.uid()))
  );
$$;

grant execute on function private.e_admin(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Campos de controle no perfil.
-- ---------------------------------------------------------------------------
alter table public.profiles add column if not exists aprovado boolean not null default false;
alter table public.profiles add column if not exists bloqueado boolean not null default false;
alter table public.profiles add column if not exists limite_dispositivos integer not null default 2;
alter table public.profiles add column if not exists observacao text;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_limite_dispositivos_check') then
    alter table public.profiles
      add constraint profiles_limite_dispositivos_check
      check (limite_dispositivos between 1 and 20);
  end if;
end $$;

comment on column public.profiles.aprovado is 'Liberado para usar a ferramenta. Nasce false: cadastro novo entra na fila de aprovação.';
comment on column public.profiles.bloqueado is 'Acesso suspenso pelo administrador, independentemente de aprovado.';
comment on column public.profiles.limite_dispositivos is 'Quantos aparelhos distintos podem acessar com esta conta.';

create or replace function private.usuario_liberado(p_id uuid default null)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = coalesce(p_id, (select auth.uid()))
      and p.aprovado
      and not p.bloqueado
  );
$$;

grant execute on function private.usuario_liberado(uuid) to authenticated;

-- Os quatro campos de controle só podem ser mexidos por admin. auth.uid() nulo
-- significa operação do servidor (migration, service_role), não requisição de
-- navegador — sem essa ressalva a própria migration que aprova o primeiro admin
-- seria barrada pelo trigger que ela acabou de criar.
create or replace function public.proteger_campos_de_controle()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null then
    return new;
  end if;

  if (new.aprovado is distinct from old.aprovado
      or new.bloqueado is distinct from old.bloqueado
      or new.limite_dispositivos is distinct from old.limite_dispositivos
      or new.observacao is distinct from old.observacao)
     and not private.e_admin() then
    raise exception 'Apenas administradores podem alterar aprovação, bloqueio, limite de dispositivos ou observação.'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

revoke all on function public.proteger_campos_de_controle() from public, anon, authenticated;

drop trigger if exists profiles_proteger_controle on public.profiles;
create trigger profiles_proteger_controle
  before update on public.profiles
  for each row
  execute function public.proteger_campos_de_controle();

-- Admin enxerga e edita todos os perfis (as policies são OR).
drop policy if exists profiles_select_admin on public.profiles;
create policy profiles_select_admin
  on public.profiles
  for select
  to authenticated
  using ( private.e_admin() );

drop policy if exists profiles_update_admin on public.profiles;
create policy profiles_update_admin
  on public.profiles
  for update
  to authenticated
  using ( private.e_admin() )
  with check ( private.e_admin() );

-- ---------------------------------------------------------------------------
-- Aparelhos e acessos.
-- "impressao" é um id aleatório gerado e guardado pelo próprio navegador —
-- não é fingerprinting, não identifica o aparelho fora desta ferramenta.
-- ---------------------------------------------------------------------------
create table if not exists public.dispositivos (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  impressao text not null,
  tipo text,
  navegador text,
  sistema text,
  fuso text,
  user_agent text,
  primeiro_acesso timestamptz not null default now(),
  ultimo_acesso timestamptz not null default now(),
  unique (user_id, impressao)
);

comment on table public.dispositivos is 'Aparelhos por onde a conta já entrou. "impressao" é um identificador aleatório guardado no navegador, não fingerprinting.';
comment on column public.dispositivos.fuso is 'Fuso horário informado pelo navegador. Aproximação regional, vinda do cliente — falsificável, serve de visibilidade operacional e não de prova.';

create index if not exists dispositivos_user_idx on public.dispositivos (user_id);

alter table public.dispositivos enable row level security;

drop policy if exists dispositivos_select_proprio_ou_admin on public.dispositivos;
create policy dispositivos_select_proprio_ou_admin
  on public.dispositivos
  for select
  to authenticated
  using ( (select auth.uid()) = user_id or private.e_admin() );

drop policy if exists dispositivos_insert_proprio on public.dispositivos;
create policy dispositivos_insert_proprio
  on public.dispositivos
  for insert
  to authenticated
  with check ( (select auth.uid()) = user_id );

drop policy if exists dispositivos_update_proprio on public.dispositivos;
create policy dispositivos_update_proprio
  on public.dispositivos
  for update
  to authenticated
  using ( (select auth.uid()) = user_id )
  with check ( (select auth.uid()) = user_id );

-- Só admin remove aparelho (é uma ação do painel).
drop policy if exists dispositivos_delete_admin on public.dispositivos;
create policy dispositivos_delete_admin
  on public.dispositivos
  for delete
  to authenticated
  using ( private.e_admin() );

create table if not exists public.acessos (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  dispositivo_id uuid references public.dispositivos (id) on delete cascade,
  quando timestamptz not null default now(),
  tipo text,
  fuso text
);

comment on table public.acessos is 'Um registro por entrada na ferramenta.';

create index if not exists acessos_user_idx on public.acessos (user_id, quando desc);

alter table public.acessos enable row level security;

drop policy if exists acessos_select_proprio_ou_admin on public.acessos;
create policy acessos_select_proprio_ou_admin
  on public.acessos
  for select
  to authenticated
  using ( (select auth.uid()) = user_id or private.e_admin() );

drop policy if exists acessos_insert_proprio on public.acessos;
create policy acessos_insert_proprio
  on public.acessos
  for insert
  to authenticated
  with check ( (select auth.uid()) = user_id );

-- O limite vale no banco, não no navegador: checagem em JS é contornada pelo
-- devtools em cinco segundos.
--
-- Armadilha do Postgres: o BEFORE INSERT dispara ANTES de o ON CONFLICT ser
-- avaliado. Se o trigger só contasse dispositivos, um upsert de aparelho já
-- registrado bateria no limite e barraria o usuário no computador de sempre.
-- Por isso ele retorna cedo quando a impressão já existe para aquele usuário.
create or replace function public.aplicar_limite_dispositivos()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limite integer;
  v_total integer;
begin
  if exists (
    select 1 from public.dispositivos d
    where d.user_id = new.user_id and d.impressao = new.impressao
  ) then
    return new;
  end if;

  select p.limite_dispositivos into v_limite
  from public.profiles p where p.id = new.user_id;
  v_limite := coalesce(v_limite, 2);

  select count(*) into v_total
  from public.dispositivos d where d.user_id = new.user_id;

  if v_total >= v_limite then
    raise exception 'Limite de % aparelho(s) atingido para esta conta.', v_limite
      using errcode = '42501';
  end if;

  return new;
end;
$$;

revoke all on function public.aplicar_limite_dispositivos() from public, anon, authenticated;

drop trigger if exists dispositivos_aplicar_limite on public.dispositivos;
create trigger dispositivos_aplicar_limite
  before insert on public.dispositivos
  for each row
  execute function public.aplicar_limite_dispositivos();

-- ---------------------------------------------------------------------------
-- A aprovação vira barreira de verdade: sem ela o RLS nega a base fiscal e não
-- há o que a ferramenta consulte. Aviso na tela seria só decoração.
-- ---------------------------------------------------------------------------
drop policy if exists ncm_select_autenticado on public.ncm;
drop policy if exists ncm_select_liberado on public.ncm;
create policy ncm_select_liberado
  on public.ncm
  for select
  to authenticated
  using ( private.usuario_liberado() );

drop policy if exists ncm_versao_select_autenticado on public.ncm_versao;
drop policy if exists ncm_versao_select_liberado on public.ncm_versao;
create policy ncm_versao_select_liberado
  on public.ncm_versao
  for select
  to authenticated
  using ( private.usuario_liberado() );
