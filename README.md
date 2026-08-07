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

> **O que o login protege, e o que não protege.** Sem sessão válida — e, desde o painel
> de administração, sem aprovação — o `select` em `public.ncm` é negado pelo RLS: a base
> fiscal em si passa a ser de acesso controlado. Mas o `index.html` continua sendo um
> arquivo estático público, com a lógica de cálculo à vista no código-fonte; e, uma vez
> sincronizada, a base fica no `localStorage` daquele navegador inclusive depois do
> logout — é o preço de funcionar offline. O login controla quem **obtém** a base, não o
> que a pessoa faz com ela depois.

## Administração de acessos

Aba **Administração**, visível apenas para administradores, criada por
[`20260807124616_criar_administracao_admins_dispositivos_acessos.sql`](supabase/migrations/20260807124616_criar_administracao_admins_dispositivos_acessos.sql)
e [`20260807124640_criar_funcoes_do_painel_admin.sql`](supabase/migrations/20260807124640_criar_funcoes_do_painel_admin.sql).

### Por que a flag de admin não fica em `profiles`

Usuários têm policy de `update` no próprio perfil. Uma coluna `admin` ali seria
**auto-atribuível**: qualquer um viraria administrador sozinho com um `PATCH`. Por isso
existe `public.admins`, uma tabela separada **sem nenhuma policy de escrita para o
cliente** — entra e sai dela só pelas funções `promover_admin` e `rebaixar_admin`, que
checam administrador antes de qualquer coisa.

Pelo mesmo motivo, os quatro campos de controle que ficam em `profiles` (`aprovado`,
`bloqueado`, `limite_dispositivos`, `observacao`) são protegidos pelo trigger
`profiles_proteger_controle`, que recusa a alteração quando quem atualiza não é admin.
O trigger libera quando `auth.uid()` é nulo, que significa operação de servidor
(migration, `service_role`) e não requisição de navegador — sem essa ressalva, a própria
migration que aprova o primeiro administrador seria barrada pelo trigger que ela acabou
de criar.

### Tabelas

| tabela | o que guarda |
|---|---|
| `public.admins` | `id` (FK para `auth.users`), `criado_em`, `criado_por`. Select só da própria linha — é assim que o frontend sabe se mostra a aba. |
| `public.dispositivos` | `impressao`, `tipo`, `navegador`, `sistema`, `fuso`, `user_agent`, `primeiro_acesso`, `ultimo_acesso`, com `unique (user_id, impressao)`. |
| `public.acessos` | um registro por entrada: `dispositivo_id`, `quando`, `tipo`, `fuso`. |

`impressao` é um identificador **aleatório que o próprio navegador gera e guarda**. Não é
fingerprinting: não identifica o aparelho fora desta ferramenta e some se o usuário limpar
os dados do site.

### O limite de aparelhos vale no banco

`dispositivos_aplicar_limite` é um trigger `before insert`: checagem em JavaScript seria
contornada pelo devtools em cinco segundos. Ele tem uma sutileza do Postgres embutida —
o `BEFORE INSERT` dispara **antes** de o `ON CONFLICT` ser avaliado, então um trigger que
apenas contasse aparelhos barraria o usuário no computador de sempre a cada novo login.
Por isso ele retorna cedo quando a `impressao` já existe para aquele usuário.

### O schema `private`

`e_admin()` e `usuario_liberado()` são usados **dentro das policies** e por isso vivem em
`private`, que o PostgREST não expõe. Em `public` eles ganhariam rota em
`/rest/v1/rpc/...` e o `get_advisors` acusaria. A role `authenticated` recebe
`usage` no schema e `execute` nas funções porque as policies são avaliadas com os
privilégios de quem consulta.

Já `listar_usuarios()`, `promover_admin()` e `rebaixar_admin()` **precisam** ser
chamáveis por `authenticated` — é assim que o painel funciona — e por isso o
`get_advisors` mantém três avisos de *Signed-In Users Can Execute SECURITY DEFINER
Function*. São intencionais: a autorização está dentro de cada função, na primeira linha,
levantando `42501` para qualquer não-administrador. Silenciar o aviso significaria
desligar o painel.

### O que o painel faz

- Cartões de resumo: total, aprovados, aguardando, bloqueados, administradores.
- Planilha ordenável por qualquer coluna, busca por nome/e-mail/empresa, filtro por
  situação e exportação em CSV (com BOM e separador `;`, para o Excel brasileiro abrir
  sem passo intermediário).
- Detalhe do usuário: quando assinou, se confirmou o e-mail, último login, último acesso,
  total de acessos, aparelhos acima do limite, lista de aparelhos e últimos acessos.
- Ações: aprovar/revogar, bloquear/desbloquear, alterar limite, remover aparelho e tornar
  outro usuário administrador.
- Aba **API** documentando os endpoints REST que o PostgREST já expõe.

Quem não estiver liberado vê uma tela explicando a situação no lugar da ferramenta, com
textos distintos para cadastro em análise, acesso suspenso e limite de aparelhos atingido.

### Dois limites que valem dizer em voz alta

- **A "região" não vem do IP.** Sem servidor próprio, o que dá para captar é o fuso do
  navegador (`Intl.DateTimeFormat().resolvedOptions().timeZone`), que é aproximação
  regional e vem do cliente — portanto falsificável. Serve de visibilidade operacional,
  não de prova. Região por IP exigiria uma Edge Function.
- **Guardar dispositivo, fuso e histórico de acesso de usuário identificado é dado
  pessoal sob a LGPD** e precisa estar declarado para o usuário.

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
