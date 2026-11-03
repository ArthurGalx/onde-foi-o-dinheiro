-- App de finanças — tudo que vai no Supabase, num arquivo só.
-- Como usar: Supabase › SQL Editor › New query › cole tudo › Run.
-- Pode rodar de novo sem problema (usa "if not exists" / "drop ... if exists").
--
-- Parte 1: os dados do app (uma linha por pessoa, com todo o estado em JSON).
-- Parte 2: o atalho do iPhone (código secreto, caixa de entrada e registro de chamadas).
-- Toda tabela tem RLS: com a chave pública, cada pessoa só enxerga o que é dela.

-- ============ Parte 1: dados do app ============


create table if not exists public.dados (
  user_id    uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  estado     jsonb not null default '{}'::jsonb,
  atualizado timestamptz not null default now()
);

-- Sem RLS a chave pública leria tudo. Com ela, cada um só enxerga a própria linha.
alter table public.dados enable row level security;

drop policy if exists "dono lê" on public.dados;
create policy "dono lê" on public.dados for select using (auth.uid() = user_id);
drop policy if exists "dono cria" on public.dados;
create policy "dono cria" on public.dados for insert with check (auth.uid() = user_id);
drop policy if exists "dono atualiza" on public.dados;
create policy "dono atualiza" on public.dados for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists "dono apaga" on public.dados;
create policy "dono apaga" on public.dados for delete using (auth.uid() = user_id);


-- ============ Parte 2: atalho do iPhone ============
-- código secreto de cada pessoa (gerado pelo app na tela do atalho) (gerado pelo app em "Atalho do iPhone")
create table if not exists public.atalho_tokens (
  token   text primary key default replace(gen_random_uuid()::text, '-', ''),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  criado  timestamptz not null default now()
);
alter table public.atalho_tokens enable row level security;
drop policy if exists "dono lê código" on public.atalho_tokens;
create policy "dono lê código" on public.atalho_tokens for select using (auth.uid() = user_id);
drop policy if exists "dono cria código" on public.atalho_tokens;
create policy "dono cria código" on public.atalho_tokens for insert with check (auth.uid() = user_id);
drop policy if exists "dono apaga código" on public.atalho_tokens;
create policy "dono apaga código" on public.atalho_tokens for delete using (auth.uid() = user_id);

-- gastos que chegaram pelo atalho e o app ainda não puxou
create table if not exists public.entrada (
  id      bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  valor   numeric(12,2) not null,
  loja    text,
  cartao  text,
  quando  timestamptz not null default now()
);
alter table public.entrada enable row level security;
drop policy if exists "dono lê entrada" on public.entrada;
create policy "dono lê entrada" on public.entrada for select using (auth.uid() = user_id);
drop policy if exists "dono apaga entrada" on public.entrada;
create policy "dono apaga entrada" on public.entrada for delete using (auth.uid() = user_id);
-- sem policy de insert: só a função abaixo grava aqui

create table if not exists public.atalho_log (
  id      bigint generated always as identity primary key,
  user_id uuid references auth.users(id) on delete cascade,
  quando  timestamptz not null default now(),
  valor   text,
  loja    text,
  cartao  text,
  ok      boolean not null,
  erro    text
);
alter table public.atalho_log enable row level security;
drop policy if exists "dono lê log" on public.atalho_log;
create policy "dono lê log" on public.atalho_log for select using (auth.uid() = user_id);
drop policy if exists "dono apaga log" on public.atalho_log;
create policy "dono apaga log" on public.atalho_log for delete using (auth.uid() = user_id);

drop function if exists public.registrar_gasto(text, text, text, text);

create function public.registrar_gasto(token text default null, valor text default null, loja text default null, cartao text default null)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid;
  s   text;
  v   numeric;
begin
  select t.user_id into uid from atalho_tokens t where t.token = registrar_gasto.token;
  if uid is null then
    return json_build_object('ok', false, 'erro', 'código do atalho inválido');
  end if;

  begin
    -- "R$ 1.234,56", "1234,56", "1234.56", "BRL 12.90": fica só número, vírgula e ponto
    s := regexp_replace(coalesce(valor, ''), '[^0-9,.]', '', 'g');
    if position(',' in s) > 0 then
      s := replace(replace(s, '.', ''), ',', '.');
    elsif s ~ '\.\d{3}$' and s ~ '^\d{1,3}(\.\d{3})+$' then
      s := replace(s, '.', '');          -- "1.234" sem centavos é milhar
    end if;
    if s = '' then
      raise exception 'o valor chegou vazio (o cartão não mandou o valor para a Carteira)';
    end if;
    v := round(s::numeric, 2);

    insert into entrada (user_id, valor, loja, cartao)
    values (uid, v, left(nullif(trim(loja), ''), 120), left(nullif(trim(cartao), ''), 60));
    insert into atalho_log (user_id, valor, loja, cartao, ok)
    values (uid, left(valor, 200), left(loja, 200), left(cartao, 200), true);
    return json_build_object('ok', true, 'valor', v);
  exception when others then
    insert into atalho_log (user_id, valor, loja, cartao, ok, erro)
    values (uid, left(valor, 200), left(loja, 200), left(cartao, 200), false, sqlerrm);
    return json_build_object('ok', false, 'erro', sqlerrm);
  end;
end;
$$;

revoke all on function public.registrar_gasto(text, text, text, text) from public;
grant execute on function public.registrar_gasto(text, text, text, text) to anon, authenticated;
