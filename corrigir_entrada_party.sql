-- Corrige tabelas antigas sem apagar as parties existentes.
BEGIN;
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
NOTIFY pgrst, 'reload schema';
COMMIT;
