-- Base fiscal de NCM do GUIA-LP, antes embutida no index.html.
-- Servida pelo Supabase e cacheada no navegador; leitura só para quem está logado.
--
-- Esta migration é idempotente e corresponde ao que já está aplicado no projeto
-- FAROL-GUIA-LP. Os nomes de policy, função e trigger são propositalmente os do
-- GUIA-LP e NÃO os do GUIA-SN — são dois projetos Supabase distintos.

create table if not exists public.ncm (
  ncm text primary key check (ncm ~ '^[0-9]{8}$'),
  descricao text not null,
  segmento text,
  mva numeric(6,2),
  monofasico text
);

comment on table public.ncm is 'Base de NCM com segmento de ST no Acre, MVA e enquadramento monofásico de PIS/COFINS.';
comment on column public.ncm.segmento is 'Segmento de substituição tributária do RICMS/AC; nulo quando a mercadoria não é de ST.';
comment on column public.ncm.mva is 'Margem de valor agregado do segmento de ST, em percentual.';
comment on column public.ncm.monofasico is 'Grupo monofásico de PIS/COFINS; nulo quando a mercadoria não é monofásica.';

-- Índices parciais: só ~2.052 dos 10.687 registros têm segmento e ~550 têm
-- grupo monofásico, então o índice cobre apenas as linhas que interessam.
create index if not exists ncm_segmento_idx on public.ncm (segmento) where segmento is not null;
create index if not exists ncm_monofasico_idx on public.ncm (monofasico) where monofasico is not null;

alter table public.ncm enable row level security;

-- A base inteira é visível para qualquer usuário autenticado. Sem policy de
-- escrita: recarregar a base é tarefa do service_role, fora do navegador.
drop policy if exists ncm_select_autenticado on public.ncm;
create policy ncm_select_autenticado
  on public.ncm
  for select
  to authenticated
  using ( true );

-- Linha única com a versão da base. O cliente compara esta versão com a do
-- cache no localStorage e só baixa os dados quando elas diferem.
create table if not exists public.ncm_versao (
  id boolean primary key default true check (id),
  versao text not null,
  fonte text,
  total integer,
  atualizado_em timestamptz not null default now()
);

comment on table public.ncm_versao is 'Versão corrente da base de NCM (linha única). Alimentada por trigger a partir do conteúdo de public.ncm.';
comment on column public.ncm_versao.versao is 'md5 do conteúdo inteiro de public.ncm — muda sempre que qualquer registro muda.';

alter table public.ncm_versao enable row level security;

drop policy if exists ncm_versao_select_autenticado on public.ncm_versao;
create policy ncm_versao_select_autenticado
  on public.ncm_versao
  for select
  to authenticated
  using ( true );

-- Recalcula a versão a cada statement que toque em public.ncm. É isso que
-- impede a versão de ficar atrasada em relação aos dados e, por consequência,
-- impede um navegador de ficar preso a um cache velho.
create or replace function public.atualizar_ncm_versao()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hash text;
  v_total integer;
begin
  select
    md5(coalesce(string_agg(
      n.ncm || '|' || n.descricao || '|' || coalesce(n.segmento, '') || '|' ||
      coalesce(n.mva::text, '') || '|' || coalesce(n.monofasico, ''),
      chr(10) order by n.ncm
    ), '')),
    count(*)
  into v_hash, v_total
  from public.ncm n;

  insert into public.ncm_versao (id, versao, total, atualizado_em)
  values (true, v_hash, v_total, now())
  on conflict (id) do update
    set versao = excluded.versao,
        total = excluded.total,
        atualizado_em = excluded.atualizado_em;

  return null;
end;
$$;

-- Função de trigger não deve ser chamável via /rest/v1/rpc/...
revoke all on function public.atualizar_ncm_versao() from public, anon, authenticated;

drop trigger if exists ncm_atualiza_versao on public.ncm;
create trigger ncm_atualiza_versao
  after insert or update or delete or truncate on public.ncm
  for each statement
  execute function public.atualizar_ncm_versao();
