# Carga da base de NCM

`ncm.json` é a base fiscal que antes ficava embutida no `index.html`. Mantém o formato
compacto de origem para poder ser carregada no Postgres sem transformação intermediária:

```json
{
  "segs":  ["Alimentícios", "Autopeças", "..."],
  "monos": ["Autopeças", "Bebidas frias", "..."],
  "rows":  ["22030000|CERVEJA DE MALTE|20|140|1", "..."]
}
```

Cada linha de `rows` tem cinco campos separados por `|`:
`ncm | descrição | índice em segs | mva | índice em monos`. Os índices vazios viram
`null` no banco. Nenhuma descrição contém `|`, então `split_part` é seguro.

## Recarregar a base no Supabase

O sandbox não alcança a API do Supabase e o arquivo é grande demais para passar por
chamada de ferramenta, então quem busca o arquivo é o próprio banco. A extensão `http`
é criada só para isso e **removida em seguida** — ela permite requisições HTTP de saída
a partir do Postgres, o que é superfície de SSRF.

```sql
create extension if not exists http with schema extensions;

with baixado as (
  select ((extensions.http_get(
    'https://raw.githubusercontent.com/CPUSISCODE/GUIA-LP/<commit>/supabase/seed/ncm.json'
  )).content)::jsonb as j
),
linhas as (
  select j, jsonb_array_elements_text(j -> 'rows') as r from baixado
)
insert into public.ncm (ncm, descricao, segmento, mva, monofasico)
select
  split_part(r, '|', 1),
  split_part(r, '|', 2),
  case when split_part(r, '|', 3) = '' then null
       else j -> 'segs' ->> (split_part(r, '|', 3))::int end,
  nullif(split_part(r, '|', 4), '')::numeric,
  case when split_part(r, '|', 5) = '' then null
       else j -> 'monos' ->> (split_part(r, '|', 5))::int end
from linhas
on conflict (ncm) do update
  set descricao = excluded.descricao,
      segmento = excluded.segmento,
      mva = excluded.mva,
      monofasico = excluded.monofasico;

update public.ncm_versao set fonte = 'supabase/seed/ncm.json @ <commit>' where id;

drop extension http;   -- obrigatório
```

Use o **SHA do commit** na URL, não o nome do branch: assim a carga é reprodutível e
não muda debaixo dos pés se o arquivo for alterado depois.

O trigger `ncm_atualiza_versao` recalcula sozinho o md5 e o total em `public.ncm_versao`.
Como a versão muda junto com os dados, todo navegador com cache antigo baixa a base nova
no próximo login — não é preciso avisar ninguém nem limpar cache manualmente.

## Conferir a carga

O md5 gravado em `ncm_versao.versao` pode ser reproduzido a partir do arquivo:

```bash
node -e "
const crypto=require('crypto');
const db=JSON.parse(require('fs').readFileSync('supabase/seed/ncm.json','utf8'));
const linhas=db.rows.map(r=>{const p=r.split('|');return{
  ncm:p[0], desc:p[1],
  seg:p[2]!==''?db.segs[+p[2]]:null,
  mva:p[3]!==''?Number(p[3]).toFixed(2):null,
  mono:p[4]!==''?db.monos[+p[4]]:null};});
linhas.sort((a,b)=>a.ncm<b.ncm?-1:1);
const texto=linhas.map(l=>[l.ncm,l.desc,l.seg||'',l.mva||'',l.mono||''].join('|')).join('\n');
console.log(crypto.createHash('md5').update(texto,'utf8').digest('hex'));
"
```

Carga de 06/08/2026: 10.687 registros, 2.052 com segmento de ST, 550 monofásicos,
md5 `3c6f2f93993dc9517d33e9c88ccac4dc`.
