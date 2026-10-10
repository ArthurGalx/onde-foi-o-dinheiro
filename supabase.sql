-- Onde foi o dinheiro — tabela da nuvem.
-- Rode isto uma vez no Supabase: SQL Editor › New query › cole › Run.
-- Cada pessoa tem uma linha só, com todo o estado do app em "estado".

create table if not exists public.dados (
  user_id    uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  estado     jsonb not null default '{}'::jsonb,
  atualizado timestamptz not null default now()
);

-- Sem RLS a chave pública leria tudo. Com ela, cada um só enxerga a própria linha.
alter table public.dados enable row level security;

create policy "dono lê"      on public.dados for select using (auth.uid() = user_id);
create policy "dono cria"    on public.dados for insert with check (auth.uid() = user_id);
create policy "dono atualiza" on public.dados for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "dono apaga"   on public.dados for delete using (auth.uid() = user_id);
