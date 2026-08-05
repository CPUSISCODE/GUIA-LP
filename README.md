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

- **RLS habilitado**: cada usuário só lê e altera o próprio perfil, pelas policies
  `"Usuários podem ver o próprio perfil"`, `"Usuários podem criar o próprio perfil"`
  e `"Usuários podem atualizar o próprio perfil"`.
- **Trigger `on_auth_user_created`**: cria o perfil automaticamente no cadastro,
  copiando `nome` e `empresa` dos metadados do usuário.
- **Trigger `set_profiles_updated_at`**: mantém `updated_at` em dia.

O esquema está versionado em
[`supabase/migrations/20260805142414_criar_tabela_profiles_com_rls_e_triggers.sql`](supabase/migrations/20260805142414_criar_tabela_profiles_com_rls_e_triggers.sql).
Aplique-o com `supabase db push` ou colando o conteúdo no **SQL Editor** do painel.
`nome` e `empresa` aparecem na barra de usuário no topo da página depois do login.

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

- `@supabase/supabase-js` 2.58.0 — autenticação
- `xlsx` 0.18.5 — importação de planilhas
