-- Onde foi o dinheiro — caixa de entrada do atalho do iPhone.
-- Rode isto uma vez no Supabase: SQL Editor › New query › cole › Run.
--
-- O atalho não faz login: ele manda um código secreto seu junto com o gasto.
-- A função registrar_gasto troca o código pelo seu usuário e guarda o gasto
-- em "entrada"; o app, logado, puxa dali e apaga o que já guardou.

-- código secreto de cada pessoa (gerado pelo app em "Atalho do iPhone")
create table if not exists public.atalho_tokens (
  token   text primary key default replace(gen_random_uuid()::text, '-', ''),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  criado  timestamptz not null default now()
);
alter table public.atalho_tokens enable row level security;
create policy "dono lê código"   on public.atalho_tokens for select using (auth.uid() = user_id);
create policy "dono cria código" on public.atalho_tokens for insert with check (auth.uid() = user_id);
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
create policy "dono lê entrada"   on public.entrada for select using (auth.uid() = user_id);
create policy "dono apaga entrada" on public.entrada for delete using (auth.uid() = user_id);
-- sem policy de insert: só a função abaixo grava aqui

-- valor chega como texto porque o iPhone manda "R$ 23,90", "23,90" ou "23.9"
create or replace function public.registrar_gasto(token text, valor text, loja text default null, cartao text default null)
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
    raise exception 'código do atalho inválido';
  end if;
  s := regexp_replace(coalesce(valor, ''), '[^0-9,.]', '', 'g');
  if position(',' in s) > 0 then
    s := replace(replace(s, '.', ''), ',', '.');
  end if;
  if s = '' then
    raise exception 'valor vazio';
  end if;
  v := round(s::numeric, 2);
  insert into entrada (user_id, valor, loja, cartao)
  values (uid, v, left(nullif(trim(loja), ''), 120), left(nullif(trim(cartao), ''), 60));
  return json_build_object('ok', true, 'valor', v, 'loja', loja);
end;
$$;

revoke all on function public.registrar_gasto(text, text, text, text) from public;
grant execute on function public.registrar_gasto(text, text, text, text) to anon, authenticated;
