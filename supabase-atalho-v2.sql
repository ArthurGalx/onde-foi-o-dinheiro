-- Onde foi o dinheiro — atalho do iPhone, versão 2.
-- Rode isto uma vez no Supabase: SQL Editor › New query › cole › Run.
-- (Precisa do supabase-atalho.sql já rodado antes.)
--
-- O que muda:
--  * a função nunca devolve erro para o iPhone: se algo vier num formato
--    inesperado, ela responde {"ok": false, "erro": ...} e anota o problema;
--  * toda chamada fica registrada em atalho_log (o que chegou e se deu certo),
--    e o app mostra as últimas na janela "Atalho do iPhone";
--  * campos que não vierem (loja, cartão) não quebram a chamada.

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
drop policy if exists "dono apaga log" on public.atalho_log;
create policy "dono lê log"    on public.atalho_log for select using (auth.uid() = user_id);
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
