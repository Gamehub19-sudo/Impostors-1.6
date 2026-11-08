-- CORREÇÃO COMPLETA: execute todo este arquivo no SQL Editor do projeto do jogo.
-- Cria a estrutura que faltar e atualiza as funções sem apagar parties ou jogadores.
-- Anonymous Sign-ins deve estar ativado em Authentication.
BEGIN;
create table if not exists public.ii_rooms (
 code text primary key, host_id uuid not null, status text not null default 'waiting'
 check(status in ('waiting','playing')), meeting_until timestamptz,
 created_at timestamptz not null default now()
);
create table if not exists public.ii_players (
 room_code text not null references public.ii_rooms(code) on delete cascade,
 user_id uuid not null, name text not null, role text check(role in ('impostor','innocent')),
 alive boolean not null default true, tasks int not null default 0,
 joined_at timestamptz not null default now(), primary key(room_code,user_id)
);
create table if not exists public.ii_events (
 id bigint generated always as identity primary key,
 room_code text not null references public.ii_rooms(code) on delete cascade,
 kind text not null check(kind in ('kill','sabotage','report')),
 target_id uuid, killer_name text, created_at timestamptz not null default now()
);
ALTER TABLE public.ii_rooms ADD COLUMN IF NOT EXISTS meeting_until timestamptz;
ALTER TABLE public.ii_rooms ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE public.ii_players ADD COLUMN IF NOT EXISTS alive boolean NOT NULL DEFAULT true;
ALTER TABLE public.ii_players ADD COLUMN IF NOT EXISTS tasks integer NOT NULL DEFAULT 0;
ALTER TABLE public.ii_players ADD COLUMN IF NOT EXISTS joined_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE public.ii_players ADD COLUMN IF NOT EXISTS role text;
ALTER TABLE public.ii_events ADD COLUMN IF NOT EXISTS id bigint GENERATED ALWAYS AS IDENTITY;
ALTER TABLE public.ii_events ADD COLUMN IF NOT EXISTS kind text;
ALTER TABLE public.ii_events ADD COLUMN IF NOT EXISTS target_id uuid;
ALTER TABLE public.ii_events ADD COLUMN IF NOT EXISTS killer_name text;
ALTER TABLE public.ii_events ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now();

create index if not exists ii_events_room_idx on public.ii_events(room_code,id);
alter table public.ii_rooms enable row level security;
alter table public.ii_players enable row level security;
alter table public.ii_events enable row level security;
revoke all on public.ii_rooms,public.ii_players,public.ii_events from anon,authenticated;


ALTER TABLE public.ii_rooms ADD COLUMN IF NOT EXISTS max_players integer NOT NULL DEFAULT 12;
ALTER TABLE public.ii_rooms ADD COLUMN IF NOT EXISTS impostor_count integer NOT NULL DEFAULT 1;
ALTER TABLE public.ii_rooms DROP CONSTRAINT IF EXISTS ii_rooms_limits;
ALTER TABLE public.ii_rooms ADD CONSTRAINT ii_rooms_limits CHECK (max_players BETWEEN 2 AND 12 AND impostor_count BETWEEN 1 AND max_players-1);

CREATE OR REPLACE FUNCTION public.ii_create_room(p_name text,p_max_players integer,p_impostor_count integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE c text; i integer; made boolean:=false;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Ative Anonymous Sign-ins em Authentication'; END IF;
 IF length(trim(coalesce(p_name,''))) NOT BETWEEN 2 AND 20 THEN RAISE EXCEPTION 'Nome deve ter 2 a 20 caracteres'; END IF;
 IF p_max_players IS NULL OR p_impostor_count IS NULL OR p_max_players NOT BETWEEN 2 AND 12 OR p_impostor_count NOT BETWEEN 1 AND p_max_players-1 THEN
  RAISE EXCEPTION 'Escolha 2 a 12 jogadores e menos impostores que jogadores'; END IF;
 FOR i IN 1..25 LOOP
  c:=upper(substr(replace(pg_catalog.gen_random_uuid()::text,'-',''),1,6));
  INSERT INTO public.ii_rooms(code,host_id,max_players,impostor_count)
  VALUES(c,auth.uid(),p_max_players,p_impostor_count) ON CONFLICT DO NOTHING;
  IF FOUND THEN made:=true; EXIT; END IF;
 END LOOP;
 IF NOT made THEN RAISE EXCEPTION 'Não foi possível gerar o código'; END IF;
 INSERT INTO public.ii_players(room_code,user_id,name) VALUES(c,auth.uid(),trim(p_name));
 RETURN jsonb_build_object(
 'code',c,'status','waiting','is_host',true,
 'max_players',p_max_players,'impostor_count',p_impostor_count,
 'players',jsonb_build_array(jsonb_build_object(
  'id',auth.uid(),'name',trim(p_name),'alive',true,'tasks',0,'is_host',true
 )), 'role',NULL,'alive',true,'tasks',0,'latest_id',0,'events','[]'::jsonb
 );
END $$;

CREATE OR REPLACE FUNCTION public.ii_join_room(p_code text,p_name text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE r public.ii_rooms%rowtype;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Não autenticado'; END IF;
 IF p_code IS NULL OR upper(trim(p_code)) !~ '^[A-F0-9]{6}$' THEN RAISE EXCEPTION 'Código da party inválido'; END IF;
 IF length(trim(coalesce(p_name,''))) NOT BETWEEN 2 AND 20 THEN RAISE EXCEPTION 'Nome inválido'; END IF;
 SELECT * INTO r FROM public.ii_rooms WHERE code=upper(trim(p_code)) FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Party não encontrada'; END IF;
 IF r.status<>'waiting' THEN RAISE EXCEPTION 'Partida já começou'; END IF;
 IF (SELECT count(*) FROM public.ii_players WHERE room_code=r.code)>=r.max_players
 AND NOT EXISTS(SELECT 1 FROM public.ii_players WHERE room_code=r.code AND user_id=auth.uid())
 THEN RAISE EXCEPTION 'Sala cheia'; END IF;
 INSERT INTO public.ii_players(room_code,user_id,name) VALUES(r.code,auth.uid(),trim(p_name))
 ON CONFLICT(room_code,user_id) DO UPDATE SET name=excluded.name;
 RETURN public.ii_room_state(r.code,0);
END $$;

CREATE OR REPLACE FUNCTION public.ii_list_rooms()
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT coalesce(jsonb_agg(x),'[]'::jsonb) FROM (
  SELECT r.code,r.max_players,r.impostor_count,
   (SELECT count(*) FROM public.ii_players p WHERE p.room_code=r.code) AS count
  FROM public.ii_rooms r WHERE r.status='waiting'
   AND r.created_at>now()-interval '24 hours'
  ORDER BY r.created_at DESC LIMIT 30
 ) x;
$$;

CREATE OR REPLACE FUNCTION public.ii_start_room(p_code text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE r public.ii_rooms%rowtype; n integer;
BEGIN
 SELECT * INTO r FROM public.ii_rooms WHERE code=upper(trim(p_code)) FOR UPDATE;
 IF NOT FOUND OR r.host_id IS DISTINCT FROM auth.uid() THEN RAISE EXCEPTION 'Somente o anfitrião pode começar'; END IF;
 IF r.status<>'waiting' THEN RAISE EXCEPTION 'Partida já começou'; END IF;
 SELECT count(*) INTO n FROM public.ii_players WHERE room_code=r.code;
 IF n < r.impostor_count+1 THEN
  RAISE EXCEPTION 'São necessários pelo menos % jogadores para % impostor(es)',r.impostor_count+1,r.impostor_count;
 END IF;
 UPDATE public.ii_players SET role='innocent',alive=true,tasks=0 WHERE room_code=r.code;
 UPDATE public.ii_players SET role='impostor' WHERE room_code=r.code AND user_id IN (
  SELECT user_id FROM public.ii_players WHERE room_code=r.code ORDER BY random() LIMIT r.impostor_count
 );
 UPDATE public.ii_rooms SET status='playing',meeting_until=NULL WHERE code=r.code;
END $$;

CREATE OR REPLACE FUNCTION public.ii_room_state(p_code text,p_after bigint DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE r public.ii_rooms%rowtype; me public.ii_players%rowtype; people jsonb; ev jsonb; latest bigint;
BEGIN
 SELECT * INTO r FROM public.ii_rooms WHERE code=upper(trim(p_code));
 IF NOT FOUND THEN RETURN jsonb_build_object('error','Party não encontrada'); END IF;
 SELECT * INTO me FROM public.ii_players WHERE room_code=r.code AND user_id=auth.uid();
 IF NOT FOUND THEN RETURN jsonb_build_object('error','Você não está nesta party'); END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',p.user_id,'name',p.name,'alive',p.alive,'tasks',p.tasks,'is_host',p.user_id=r.host_id) ORDER BY (p.user_id=r.host_id) DESC,p.joined_at,p.user_id),'[]'::jsonb)
 INTO people FROM public.ii_players p WHERE p.room_code=r.code;
 SELECT coalesce(max(id),0) INTO latest FROM public.ii_events WHERE room_code=r.code;
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',e.id,'kind',e.kind,'target_id',e.target_id,
 'killer_name',CASE WHEN e.target_id=auth.uid() THEN e.killer_name ELSE NULL END) ORDER BY e.id),'[]'::jsonb)
 INTO ev FROM (SELECT * FROM public.ii_events WHERE room_code=r.code AND id>greatest(p_after,0) ORDER BY id LIMIT 100) e;
 RETURN jsonb_build_object('code',r.code,'status',r.status,'is_host',r.host_id=auth.uid(),
 'max_players',r.max_players,'impostor_count',r.impostor_count,
 'players',people,'role',CASE WHEN r.status='playing' THEN me.role ELSE NULL END,
 'alive',me.alive,'tasks',me.tasks,'meeting_until',r.meeting_until,'events',ev,'latest_id',latest);
END $$;

REVOKE ALL ON FUNCTION public.ii_create_room(text,integer,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.ii_create_room(text,integer,integer) TO authenticated;
-- Remove a versão antiga para evitar criação de salas sem opções.
DROP FUNCTION IF EXISTS public.ii_create_room(text);

create or replace function public.ii_action(p_code text,p_kind text,p_target uuid default null)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare r ii_rooms%rowtype; me ii_players%rowtype; victim ii_players%rowtype;
begin
 select * into r from ii_rooms where code=upper(trim(p_code)) for update;
 if not found or r.status<>'playing' then raise exception 'A partida não está ativa';end if;
 select * into me from ii_players where room_code=r.code and user_id=auth.uid();
 if not found then raise exception 'Você não está na partida';end if;
 if r.meeting_until is not null and r.meeting_until>now() then raise exception 'Reunião em andamento';end if;
 if p_kind='task' then
  if me.tasks>=5 then raise exception 'Você já concluiu as 5 tarefas';end if;
  update ii_players set tasks=tasks+1 where room_code=r.code and user_id=auth.uid();
  return jsonb_build_object('ok',true);
 elsif p_kind='kill' then
  if me.role<>'impostor' or not me.alive then raise exception 'Você não pode eliminar';end if;
  if p_target=auth.uid() then raise exception 'Não pode eliminar a si mesmo';end if;
  select * into victim from ii_players where room_code=r.code and user_id=p_target for update;
  if not found or not victim.alive then raise exception 'Jogador não disponível';end if;
  update ii_players set alive=false where room_code=r.code and user_id=p_target;
  insert into ii_events(room_code,kind,target_id,killer_name)
  values(r.code,'kill',p_target,me.name);
  return jsonb_build_object('ok',true);
 elsif p_kind='sabotage' then
  if me.role<>'impostor' or not me.alive then raise exception 'Somente o impostor vivo pode sabotar';end if;
  insert into ii_events(room_code,kind) values(r.code,'sabotage');
  return jsonb_build_object('ok',true);
 elsif p_kind='report' then
  if not me.alive then raise exception 'Fantasmas não podem reportar';end if;
  update ii_rooms set meeting_until=now()+interval '15 seconds' where code=r.code;
  insert into ii_events(room_code,kind) values(r.code,'report');
  return jsonb_build_object('ok',true);
 else raise exception 'Ação inválida';end if;
end $$;

create or replace function public.ii_leave_room(p_code text) returns void
language plpgsql security definer set search_path=pg_catalog,public as $$
declare r ii_rooms%rowtype; next_host uuid;
begin
 select * into r from ii_rooms where code=upper(trim(p_code)) for update;
 if not found then return;end if;
 delete from ii_players where room_code=r.code and user_id=auth.uid();
 if not exists(select 1 from ii_players where room_code=r.code) then
  delete from ii_rooms where code=r.code;
 elsif r.host_id=auth.uid() then
  select user_id into next_host from ii_players where room_code=r.code order by joined_at limit 1;
  update ii_rooms set host_id=next_host where code=r.code;
 end if;
end $$;


REVOKE ALL ON FUNCTION public.ii_join_room(text,text),public.ii_list_rooms(),public.ii_room_state(text,bigint),public.ii_start_room(text),public.ii_action(text,text,uuid),public.ii_leave_room(text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.ii_join_room(text,text),public.ii_list_rooms(),public.ii_room_state(text,bigint),public.ii_start_room(text),public.ii_action(text,text,uuid),public.ii_leave_room(text) TO authenticated;
NOTIFY pgrst, 'reload schema';
COMMIT;
