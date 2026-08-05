-- Baseline do esquema de perfis do GUIA-LP (projeto FAROL-GUIA-LP).
--
-- Esta migration versiona o que já existe no banco, aplicado manualmente pelo
-- SQL Editor antes de o repositório ter migrations. É idempotente: rodar de
-- novo no projeto atual não altera nada. Os nomes de policy, função e trigger
-- são propositalmente os do GUIA-LP e NÃO os do GUIA-SN — são dois projetos
-- Supabase distintos, cada um com o seu banco.

create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  nome text,
  empresa text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.profiles is 'Perfil do usuário do GUIA-LP, espelhando auth.users com dados de cadastro (nome e empresa).';

alter table public.profiles enable row level security;

-- Policies: cada usuário autenticado só enxerga e altera o próprio perfil.
-- (select auth.uid()) é avaliado uma única vez por consulta (initplan),
-- evitando reavaliação por linha.

drop policy if exists profiles_select_own on public.profiles;
create policy profiles_select_own
  on public.profiles
  for select
  to authenticated
  using ( (select auth.uid()) = id );

drop policy if exists profiles_insert_own on public.profiles;
create policy profiles_insert_own
  on public.profiles
  for insert
  to authenticated
  with check ( (select auth.uid()) = id );

drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own
  on public.profiles
  for update
  to authenticated
  using ( (select auth.uid()) = id )
  with check ( (select auth.uid()) = id );

-- Mantém updated_at sempre em dia.
create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists profiles_set_updated_at on public.profiles;
create trigger profiles_set_updated_at
  before update on public.profiles
  for each row
  execute function public.set_updated_at();

-- Cria o perfil automaticamente no cadastro, aproveitando os campos enviados
-- em options.data do signUp (raw_user_meta_data). São eles que alimentam o
-- nome e a empresa exibidos na barra de usuário.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, nome, empresa)
  values (
    new.id,
    nullif(new.raw_user_meta_data ->> 'nome', ''),
    nullif(new.raw_user_meta_data ->> 'empresa', '')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row
  execute function public.handle_new_user();
