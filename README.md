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
> por hora. Para uso real, configure um SMTP próprio em **Project Settings → Auth → SMTP**.

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
