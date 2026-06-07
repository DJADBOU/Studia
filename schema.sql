-- ============================================================
-- Studia — schéma de base (à exécuter dans Supabase → SQL Editor)
-- Script idempotent : peut être ré-exécuté sans risque.
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
drop policy if exists "voir_mon_abonnement" on subscribers;
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
alter table contenus add column if not exists corrige_path text;
alter table contenus add column if not exists video_corrige_url text;
alter table contenus enable row level security;

drop policy if exists "contenus_gratuits_publics" on contenus;
create policy "contenus_gratuits_publics" on contenus
  for select using (gratuit = true);

drop policy if exists "contenus_abonnes" on contenus;
create policy "contenus_abonnes" on contenus
  for select to authenticated
  using (exists (
    select 1 from subscribers s
    where s.user_id = auth.uid() and s.status = 'active'
  ));

drop policy if exists "contenus_admin_ecriture" on contenus;
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

drop policy if exists "matieres_hidden_public_read" on matieres_hidden;
create policy "matieres_hidden_public_read" on matieres_hidden
  for select using (true);

drop policy if exists "matieres_hidden_admin_write" on matieres_hidden;
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
--                       - fondateurs : jade.jpg, ellis.jpg
--                    Le site charge ces fichiers depuis l'URL publique du bucket.
--                    Tant qu'un fichier est absent, le site fallback élégamment
--                    (badge à initiale pour les logos, gradient vert pour les photos).

-- Storage policies pour "assets" : tout le monde peut lire, seul l'admin écrit
drop policy if exists "assets_public_read" on storage.objects;
create policy "assets_public_read" on storage.objects
  for select using (bucket_id = 'assets');

drop policy if exists "assets_admin_write" on storage.objects;
create policy "assets_admin_write" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'assets' and auth.jwt() ->> 'email' = 'djad@studia.app');

drop policy if exists "assets_admin_update" on storage.objects;
create policy "assets_admin_update" on storage.objects
  for update to authenticated
  using (bucket_id = 'assets' and auth.jwt() ->> 'email' = 'djad@studia.app');

drop policy if exists "assets_admin_delete" on storage.objects;
create policy "assets_admin_delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'assets' and auth.jwt() ->> 'email' = 'djad@studia.app');

-- 6) Profils utilisateurs (créés à l'inscription, complétés par l'étudiant)
create table if not exists profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  prenom text,
  nom text,
  univ text,
  faculte text,
  annee text,
  avatar_url text,
  bio text,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
alter table profiles enable row level security;

drop policy if exists "profiles_self_read" on profiles;
create policy "profiles_self_read" on profiles
  for select to authenticated using (user_id = auth.uid());

drop policy if exists "profiles_admin_read" on profiles;
create policy "profiles_admin_read" on profiles
  for select to authenticated using (auth.jwt() ->> 'email' = 'djad@studia.app');

drop policy if exists "profiles_self_upsert" on profiles;
create policy "profiles_self_upsert" on profiles
  for insert to authenticated with check (user_id = auth.uid());

drop policy if exists "profiles_self_update" on profiles;
create policy "profiles_self_update" on profiles
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- 7) Vues : tracking des contenus consultés + temps passé
create table if not exists views (
  id bigserial primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  contenu_id text not null,
  duration_seconds int default 0,
  completed boolean default false,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
create index if not exists views_user_idx on views(user_id);
create index if not exists views_contenu_idx on views(contenu_id);
alter table views enable row level security;

drop policy if exists "views_self_read" on views;
create policy "views_self_read" on views
  for select to authenticated using (user_id = auth.uid());

drop policy if exists "views_admin_read" on views;
create policy "views_admin_read" on views
  for select to authenticated using (auth.jwt() ->> 'email' = 'djad@studia.app');

drop policy if exists "views_self_insert" on views;
create policy "views_self_insert" on views
  for insert to authenticated with check (user_id = auth.uid());

drop policy if exists "views_self_update" on views;
create policy "views_self_update" on views
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- 8) Téléchargements : lie chaque token QR → user qui a téléchargé
create table if not exists downloads (
  id bigserial primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  contenu_id text not null,
  token text unique not null,
  downloaded_at timestamptz default now()
);
create index if not exists downloads_token_idx on downloads(token);
alter table downloads enable row level security;

-- l'admin peut tout lire (pour la traçabilité des fuites)
drop policy if exists "downloads_admin_read" on downloads;
create policy "downloads_admin_read" on downloads
  for select to authenticated using (auth.jwt() ->> 'email' = 'djad@studia.app');

-- l'utilisateur peut voir ses propres téléchargements
drop policy if exists "downloads_self_read" on downloads;
create policy "downloads_self_read" on downloads
  for select to authenticated using (user_id = auth.uid());

-- l'edge function "download" insère avec service_role (bypass RLS)
-- mais on autorise quand même l'utilisateur connecté à insérer son propre row
drop policy if exists "downloads_self_insert" on downloads;
create policy "downloads_self_insert" on downloads
  for insert to authenticated with check (user_id = auth.uid());

-- 9) Commentaires sur les contenus (Q/R entre étudiants)
create table if not exists comments (
  id bigserial primary key,
  contenu_id text not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  texte text not null,
  created_at timestamptz default now()
);
create index if not exists comments_contenu_idx on comments(contenu_id);
alter table comments enable row level security;

drop policy if exists "comments_public_read" on comments;
create policy "comments_public_read" on comments
  for select using (true);

drop policy if exists "comments_auth_insert" on comments;
create policy "comments_auth_insert" on comments
  for insert to authenticated with check (user_id = auth.uid());

drop policy if exists "comments_self_delete" on comments;
create policy "comments_self_delete" on comments
  for delete to authenticated using (user_id = auth.uid() or auth.jwt() ->> 'email' = 'djad@studia.app');

-- Storage policies pour "sujets" : bucket privé, seul l'admin upload/lit
-- (l'edge function "download" utilise la clé service_role qui bypass la RLS)
-- Pour permettre l'affichage inline aux abonnés, on autorise les select aux users actifs :
drop policy if exists "sujets_subscriber_select" on storage.objects;
create policy "sujets_subscriber_select" on storage.objects
  for select to authenticated
  using (bucket_id = 'sujets' and exists (
    select 1 from subscribers s where s.user_id = auth.uid() and s.status = 'active'
  ));
drop policy if exists "sujets_admin_select" on storage.objects;
create policy "sujets_admin_select" on storage.objects
  for select to authenticated
  using (bucket_id = 'sujets' and auth.jwt() ->> 'email' = 'djad@studia.app');

drop policy if exists "sujets_admin_write" on storage.objects;
create policy "sujets_admin_write" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'sujets' and auth.jwt() ->> 'email' = 'djad@studia.app');

drop policy if exists "sujets_admin_update" on storage.objects;
create policy "sujets_admin_update" on storage.objects
  for update to authenticated
  using (bucket_id = 'sujets' and auth.jwt() ->> 'email' = 'djad@studia.app');

drop policy if exists "sujets_admin_delete" on storage.objects;
create policy "sujets_admin_delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'sujets' and auth.jwt() ->> 'email' = 'djad@studia.app');
