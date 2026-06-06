-- ============================================================
-- Studia — schéma de base (à exécuter dans Supabase → SQL Editor)
-- ============================================================

-- 1) Abonnés (rempli par le webhook Stripe, via la clé service_role)
create table if not exists subscribers (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text,
  stripe_customer text,
  status text default 'inactive',        -- 'active' | 'inactive'
  current_period_end timestamptz,
  updated_at timestamptz default now()
);
alter table subscribers enable row level security;
-- chacun voit uniquement son propre abonnement ; les écritures se font côté serveur (service_role)
create policy "voir_mon_abonnement" on subscribers
  for select to authenticated using (user_id = auth.uid());

-- 2) Contenus (cours / TD / examens)
create table if not exists contenus (
  id text primary key,
  source text default 'seed',
  univ text, faculte text, annee text, matiere text, type text,
  titre text, tuteur text, note text, duree text,
  gratuit boolean default false,
  flagship boolean default false,
  file_path text,                         -- chemin dans le bucket Storage "sujets" (privé)
  video_url text,                         -- URL YouTube / Vimeo de la vidéo
  description text,                       -- description / introduction du contenu
  account text, email text, date text, ts bigint,
  created_at timestamptz default now()
);
-- Migration sur une base déjà créée :
alter table contenus add column if not exists video_url text;
alter table contenus add column if not exists description text;
alter table contenus enable row level security;

-- le contenu gratuit est visible par tous
create policy "contenus_gratuits_publics" on contenus
  for select using (gratuit = true);

-- le reste n'est visible que par un abonné ACTIF (la vraie barrière, pas le floutage front)
create policy "contenus_abonnes" on contenus
  for select to authenticated
  using (exists (
    select 1 from subscribers s
    where s.user_id = auth.uid() and s.status = 'active'
  ));

-- l'admin gère les contenus : à restreindre à ton compte (remplace l'email)
create policy "contenus_admin_ecriture" on contenus
  for all to authenticated
  using (auth.jwt() ->> 'email' = 'djad@studia.app')
  with check (auth.jwt() ->> 'email' = 'djad@studia.app');

-- 3) Matières masquées (suppression "soft" depuis la console admin)
create table if not exists matieres_hidden (
  univ text not null,
  faculte text not null,
  annee text not null,
  matiere text not null,
  created_at timestamptz default now(),
  primary key (univ, faculte, annee, matiere)
);
alter table matieres_hidden enable row level security;
-- tout le monde peut lire la liste (sert à filtrer côté client)
create policy "matieres_hidden_public_read" on matieres_hidden for select using (true);
-- seul l'admin peut ajouter/supprimer
create policy "matieres_hidden_admin_write" on matieres_hidden
  for all to authenticated
  using (auth.jwt() ->> 'email' = 'djad@studia.app')
  with check (auth.jwt() ->> 'email' = 'djad@studia.app');

-- 4) Storage : 2 buckets à créer manuellement dans Supabase → Storage → New bucket
--    a) "sujets"   → bucket PRIVÉ. Reçoit les fichiers originaux uploadés par l'admin
--                    (PDF / images). Servis uniquement via l'edge function "download"
--                    qui tatoue à l'abonné qui télécharge.
--    b) "assets"   → bucket PUBLIC. Reçoit les logos et photos du site :
--                       - logos univ : uca.png, amu.png, p1.png, tse.png
--                       - hero       : hero.jpg
--                       - sections   : mission.jpg, cours.jpg, td.jpg, examen.jpg
--                       - campus     : campus-uca.jpg, campus-amu.jpg, campus-p1.jpg, campus-tse.jpg
--                    Le site charge ces fichiers depuis l'URL publique du bucket.
--                    Tant qu'un fichier est absent, le site fallback élégamment
--                    (badge à initiale pour les logos, gradient vert pour les photos).

-- Storage policies pour "assets" (à exécuter une fois le bucket créé)
-- Permet à n'importe qui de lire les fichiers (bucket public en lecture)
-- Et seulement l'admin de les uploader/remplacer.
create policy if not exists "assets_public_read" on storage.objects
  for select using (bucket_id = 'assets');
create policy if not exists "assets_admin_write" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'assets' and auth.jwt() ->> 'email' = 'djad@studia.app');
create policy if not exists "assets_admin_update" on storage.objects
  for update to authenticated
  using (bucket_id = 'assets' and auth.jwt() ->> 'email' = 'djad@studia.app');
create policy if not exists "assets_admin_delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'assets' and auth.jwt() ->> 'email' = 'djad@studia.app');
