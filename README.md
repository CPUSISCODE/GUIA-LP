# GUIA-LP — Consulta NCM · Lucro Presumido (Acre)

Ferramenta de página única (`index.html`) para consulta de NCM, importação de XML e
auditoria de cadastro no regime de Lucro Presumido, com **acesso protegido por login**.

## Autenticação

O acesso é controlado pelo Supabase Auth (e-mail + senha). Enquanto não houver sessão
válida, a tela de login cobre a aplicação e o conteúdo fica oculto.

Recursos disponíveis na tela de acesso:

- **Entrar** — login com e-mail e senha.
- **Criar conta** — cadastro com nome, empresa (opcional), e-mail e senha (mín. 8 caracteres).
- **Redefinir senha** — envio de link de recuperação por e-mail.
- **Sair** — botão no topo da página, ao lado do nome/e-mail do usuário logado.

A sessão é persistida no navegador e renovada automaticamente, então o usuário
continua logado ao voltar à página.

### Projeto Supabase

| | |
|---|---|
| Projeto | `FAROL-GUIA-LP` |
| Ref | `kzbkusjjxgsqdpgffimp` |
| URL | `https://kzbkusjjxgsqdpgffimp.supabase.co` |
| Região | `sa-east-1` |

A URL e a chave **publicável** ficam no próprio `index.html`. Essa chave é pública por
definição — a proteção real dos dados vem do Row Level Security. Nunca coloque a
`service_role` no HTML.

### Esquema do banco

Tabela `public.profiles`, ligada a `auth.users` (`on delete cascade`):

| coluna | tipo | observação |
|---|---|---|
| `id` | `uuid` | PK, referencia `auth.users(id)` |
| `nome` | `text` | vem do cadastro |
| `empresa` | `text` | opcional |
| `created_at` | `timestamptz` | default `now()` |
| `updated_at` | `timestamptz` | atualizado por trigger |

- **RLS habilitado**: cada usuário só lê e altera o próprio perfil
  (`profiles_select_own`, `profiles_insert_own`, `profiles_update_own`).
- **Trigger `on_auth_user_created`**: cria o perfil automaticamente no cadastro,
  copiando `nome` e `empresa` dos metadados do usuário.
- **Trigger `profiles_set_updated_at`**: mantém `updated_at` em dia.

O esquema está versionado em
[`supabase/migrations/20260805142414_criar_tabela_profiles_com_rls_e_triggers.sql`](supabase/migrations/20260805142414_criar_tabela_profiles_com_rls_e_triggers.sql),
como baseline idempotente do que já está aplicado no projeto **FAROL-GUIA-LP**.
`nome` e `empresa` aparecem na barra de usuário no topo da página depois do login.

### Base fiscal de NCM

A base não fica mais embutida no `index.html` — o arquivo caiu de 776 KB para 136 KB.
Ela vive em duas tabelas, criadas por
[`supabase/migrations/20260806132330_criar_tabelas_ncm_e_ncm_versao.sql`](supabase/migrations/20260806132330_criar_tabelas_ncm_e_ncm_versao.sql):

`public.ncm` — 10.687 registros

| coluna | tipo | observação |
|---|---|---|
| `ncm` | `text` | PK, `check (ncm ~ '^[0-9]{8}$')` |
| `descricao` | `text` | não nulo |
| `segmento` | `text` | segmento de ST do RICMS/AC; nulo fora da ST (2.052 preenchidos) |
| `mva` | `numeric(6,2)` | MVA do segmento, em percentual |
| `monofasico` | `text` | grupo monofásico de PIS/COFINS; nulo se não for (550 preenchidos) |

`public.ncm_versao` — linha única

| coluna | tipo | observação |
|---|---|---|
| `id` | `boolean` | PK `default true check (id)` — garante uma linha só |
| `versao` | `text` | md5 do conteúdo inteiro de `public.ncm` |
| `fonte` | `text` | de onde veio a carga |
| `total` | `integer` | quantidade de registros |
| `atualizado_em` | `timestamptz` | quando a versão mudou |

- **RLS habilitado** nas duas: `select` liberado apenas para a role `authenticated`,
  com `using (true)`. Sem policy de escrita — recarregar a base é tarefa do
  `service_role`, fora do navegador.
- **Trigger `ncm_atualiza_versao`**: statement-level em `public.ncm`, recalcula o md5 e
  o total a cada `insert`/`update`/`delete`/`truncate`. É isso que impede a versão de
  ficar atrasada em relação aos dados — e, portanto, impede um navegador de ficar preso
  a um cache velho.
- Índices parciais em `segmento` e `monofasico`, `where <coluna> is not null`.

### Sincronização e cache no navegador

Depois do login, junto com o carregamento do perfil, o app roda `sincronizarBase()`:

1. Se houver cache no `localStorage` (`guialp.base.ncm.v1`), ele é aplicado **na hora** —
   a ferramenta fica utilizável antes de qualquer conversa com o servidor.
2. Só então o app lê `public.ncm_versao`. Versão igual à do cache: não baixa nada.
   Diferente, ou sem cache: baixa em páginas de 1.000 registros (11 páginas hoje) e
   regrava o cache, que ocupa cerca de 1,3 MB.
3. Sem rede: com cache, segue funcionando offline e o status avisa; sem cache, aparece
   um pedido para conectar e recarregar a página.

O laço de download tem teto de 40 páginas: se o servidor ignorar a paginação e devolver
sempre uma página cheia, a sincronização para com erro em vez de martelar a API.

Enquanto a base não chega, busca, importação de XML e auditoria avisam que ela ainda está
carregando, em vez de responder "NCM não encontrado" — que seria mentira.

Para recarregar a base, ver [`supabase/seed/README.md`](supabase/seed/README.md).

> **O que o login protege, e o que não protege.** Sem sessão válida, o `select` em
> `public.ncm` é negado pelo RLS: a base fiscal em si passa a ser de acesso controlado.
> Mas o `index.html` continua sendo um arquivo estático público, com a lógica de cálculo
> à vista no código-fonte; e, uma vez sincronizada, a base fica no `localStorage` daquele
> navegador inclusive depois do logout — é o preço de funcionar offline. O login controla
> quem **obtém** a base, não o que a pessoa faz com ela depois.

> O GUIA-LP e o GUIA-SN usam **projetos Supabase separados** (`FAROL-GUIA-LP` e
> `FAROL-GUIA-SN`), cada um com o seu próprio banco e os seus próprios usuários.
> Os nomes de policy e de trigger diferem entre os dois e devem continuar assim —
> não copie migrations de um repositório para o outro.

## Configuração necessária no painel do Supabase

Em **Authentication → URL Configuration**, informe a URL onde a página é publicada:

- **Site URL**: endereço final da aplicação (ex.: `https://cpusiscode.github.io/guia-lp/`)
- **Redirect URLs**: a mesma URL — é para lá que apontam os links de confirmação de
  e-mail e de redefinição de senha.

Em **Authentication → Providers → Email**, decida o fluxo de cadastro:

- **Confirm email ligado** (padrão): o usuário recebe um e-mail de confirmação e só
  entra depois de confirmar. A tela avisa e volta para a aba "Entrar".
- **Confirm email desligado**: o usuário entra direto após o cadastro. Mais simples
  para uso interno, porém sem validação de que o e-mail existe.

> O envio de e-mails pelo servidor padrão do Supabase tem limite baixo de mensagens
> por hora, sai do remetente `noreply@mail.app.supabase.io` e costuma cair em spam.
> Para uso real, configure um SMTP próprio em **Project Settings → Auth → SMTP**.

### Personalizar o e-mail de confirmação

O template em português está em [`supabase/templates/confirmacao-cadastro.html`](supabase/templates/confirmacao-cadastro.html).
Para aplicá-lo, vá em **Authentication → Emails → Confirm signup** e:

1. Em **Subject heading**, use: `Confirme seu acesso — Consulta NCM Lucro Presumido`
2. Em **Message body**, cole o conteúdo do arquivo (sem o comentário do topo) e salve.

O template usa as variáveis do Supabase `{{ .ConfirmationURL }}`, `{{ .Token }}`,
`{{ .Email }}` e `{{ .Data.nome }}` — esta última vem do nome digitado no cadastro.
Alterações no painel não são versionadas: ao mudar o e-mail por lá, atualize também
o arquivo do repositório para os dois não divergirem.

### Cadastro travado em "e-mail não confirmado"

Enquanto `Confirm email` estiver ligado, o login retorna `Email not confirmed` até o
usuário clicar no link. Para liberar uma conta manualmente:

```sql
update auth.users set email_confirmed_at = now() where email = 'usuario@dominio.com';
```

## Executar localmente

Não há build. Abra o `index.html` no navegador ou sirva a pasta:

```bash
python3 -m http.server 8000
# http://localhost:8000
```

Ao servir em `localhost`, adicione `http://localhost:8000` às **Redirect URLs** do
Supabase para os links de e-mail funcionarem no ambiente local.

## Dependências (via CDN)

- `@supabase/supabase-js` 2.58.0 — autenticação e leitura da base de NCM
- `xlsx` 0.18.5 — importação de planilhas
