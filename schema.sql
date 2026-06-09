-- ============================================================
-- Studia — schéma de base (à exécuter dans Supabase → SQL Editor)
-- Script idempotent : peut être ré-exécuté sans risque.
-- ============================================================

-- 0) Fonction is_admin() — vrai si l'utilisateur connecté est admin.
--    Définie ici pour que le script soit auto-suffisant (les emails
--    correspondent aux fondateurs). Si tu gères les admins via une table,
--    remplace simplement le corps par un select sur cette table.
create or replace function is_admin() returns boolean
  language sql stable security definer set search_path = public, auth as $$
  select coalesce(auth.jwt() ->> 'email','') in ('djad@studia.app','ellis@studia.app');
$$;

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

-- 10) Favoris / bookmarks
create table if not exists bookmarks (
  user_id uuid not null references auth.users(id) on delete cascade,
  contenu_id text not null,
  created_at timestamptz default now(),
  primary key (user_id, contenu_id)
);
alter table bookmarks enable row level security;
drop policy if exists "bookmarks_self_all" on bookmarks;
create policy "bookmarks_self_all" on bookmarks
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- 11) Notes personnelles
create table if not exists notes (
  id bigserial primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  contenu_id text not null,
  texte text not null default '',
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
create index if not exists notes_user_contenu_idx on notes(user_id, contenu_id);
alter table notes enable row level security;
drop policy if exists "notes_self_all" on notes;
create policy "notes_self_all" on notes
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- 12) Candidatures tuteurs
create table if not exists tutor_applications (
  id bigserial primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  prenom text, nom text, email text, phone text,
  univ text, faculte text, annee text, matiere text, note text,
  message text,
  status text default 'pending', -- 'pending' | 'accepted' | 'rejected'
  created_at timestamptz default now()
);
alter table tutor_applications enable row level security;
drop policy if exists "tutor_apps_self_insert" on tutor_applications;
create policy "tutor_apps_self_insert" on tutor_applications
  for insert to authenticated with check (user_id = auth.uid());
drop policy if exists "tutor_apps_self_read" on tutor_applications;
create policy "tutor_apps_self_read" on tutor_applications
  for select to authenticated using (user_id = auth.uid() or is_admin());
drop policy if exists "tutor_apps_admin_update" on tutor_applications;
create policy "tutor_apps_admin_update" on tutor_applications
  for update to authenticated using (is_admin()) with check (is_admin());
-- l'admin (ou l'auteur) peut supprimer une candidature traitée
drop policy if exists "tutor_apps_delete" on tutor_applications;
create policy "tutor_apps_delete" on tutor_applications
  for delete to authenticated using (user_id = auth.uid() or is_admin());

-- Realtime : le candidat doit voir son statut changer en direct quand l'admin
-- accepte/rejette. On ajoute la table à la publication supabase_realtime (idempotent).
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'tutor_applications'
  ) then
    alter publication supabase_realtime add table tutor_applications;
  end if;
end $$;

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

-- 13) Signalements d'erreurs (feedback par sujet)
--     Un abonné/étudiant signale une faute, un lien cassé, une mauvaise réponse…
create table if not exists signalements (
  id bigserial primary key,
  contenu_id text not null,
  user_id uuid references auth.users(id) on delete set null,
  email text,
  message text not null,
  status text default 'pending',          -- 'pending' | 'resolved'
  created_at timestamptz default now()
);
create index if not exists signalements_contenu_idx on signalements(contenu_id);
create index if not exists signalements_status_idx on signalements(status);
alter table signalements enable row level security;

-- l'étudiant connecté insère son propre signalement
drop policy if exists "signalements_self_insert" on signalements;
create policy "signalements_self_insert" on signalements
  for insert to authenticated with check (user_id = auth.uid());

-- l'étudiant voit ses propres signalements, l'admin voit tout
drop policy if exists "signalements_read" on signalements;
create policy "signalements_read" on signalements
  for select to authenticated using (user_id = auth.uid() or is_admin());

-- seul l'admin met à jour le statut (traité / rouvert)
drop policy if exists "signalements_admin_update" on signalements;
create policy "signalements_admin_update" on signalements
  for update to authenticated using (is_admin()) with check (is_admin());

-- l'admin (ou l'auteur) peut supprimer
drop policy if exists "signalements_delete" on signalements;
create policy "signalements_delete" on signalements
  for delete to authenticated using (user_id = auth.uid() or is_admin());

-- 14) Contributions entraide (documents proposés par les étudiants)
--     Flux : l'étudiant propose un doc original → file d'attente admin →
--     l'admin télécharge le PDF → le ré-upload normalement via le pipeline existant.
--     RIEN n'est publié automatiquement.
create table if not exists contributions (
  id bigserial primary key,
  user_id uuid references auth.users(id) on delete set null,
  email text,
  univ text, faculte text, annee text, matiere text, type text,
  titre text not null,
  description text,
  file_path text not null,                 -- chemin dans le bucket privé "contributions"
  file_name text,
  status text default 'pending',           -- 'pending' | 'processed' | 'rejected'
  created_at timestamptz default now()
);
create index if not exists contributions_status_idx on contributions(status);
alter table contributions enable row level security;

-- l'étudiant connecté insère sa propre proposition
drop policy if exists "contributions_self_insert" on contributions;
create policy "contributions_self_insert" on contributions
  for insert to authenticated with check (user_id = auth.uid());

-- l'étudiant voit ses propres propositions, l'admin voit tout
drop policy if exists "contributions_read" on contributions;
create policy "contributions_read" on contributions
  for select to authenticated using (user_id = auth.uid() or is_admin());

-- seul l'admin change le statut (traité / rejeté / en attente)
drop policy if exists "contributions_admin_update" on contributions;
create policy "contributions_admin_update" on contributions
  for update to authenticated using (is_admin()) with check (is_admin());

-- l'admin (ou l'auteur) peut supprimer
drop policy if exists "contributions_delete" on contributions;
create policy "contributions_delete" on contributions
  for delete to authenticated using (user_id = auth.uid() or is_admin());

-- 15) Storage : bucket PRIVÉ "contributions" — à créer dans Supabase → Storage → New bucket
--     (décocher "Public"). Reçoit les fichiers bruts proposés par les étudiants.
--     L'admin les télécharge via un signed URL, vérifie, puis ré-upload dans "sujets".

-- l'étudiant connecté upload UNIQUEMENT dans son propre dossier (user_id/...)
drop policy if exists "contributions_user_upload" on storage.objects;
create policy "contributions_user_upload" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'contributions'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- l'étudiant relit ses propres fichiers ; l'admin lit tout (pour le signed URL)
drop policy if exists "contributions_user_select" on storage.objects;
create policy "contributions_user_select" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'contributions'
    and ((storage.foldername(name))[1] = auth.uid()::text or is_admin())
  );

-- l'admin peut supprimer un fichier de proposition
drop policy if exists "contributions_admin_delete" on storage.objects;
create policy "contributions_admin_delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'contributions' and is_admin());


-- ============================================================================
-- 11) PROFILS ENRICHIS + DOCUMENTS PERSO (CV / relevé de notes)
--     À exécuter tel quel : idempotent (add column if not exists / drop+create).
-- ============================================================================

-- 11.a) Nouvelles colonnes de profil
alter table profiles add column if not exists phone       text;
alter table profiles add column if not exists birthdate   date;     -- on calcule l'âge à l'affichage
alter table profiles add column if not exists genre       text;     -- 'Homme' | 'Femme' | 'Autre' | 'Non précisé'
alter table profiles add column if not exists ville       text;
alter table profiles add column if not exists adresse     text;
alter table profiles add column if not exists semestre    text default 'S1';  -- S1 | S2 (semestre d'inscription)
alter table profiles add column if not exists linkedin    text;     -- URL (optionnel)
alter table profiles add column if not exists cv_path     text;     -- chemin storage bucket 'documents' (optionnel)
alter table profiles add column if not exists releve_path text;     -- chemin storage bucket 'documents' (optionnel)

-- 11.b) Bucket PRIVÉ 'documents' : CV + relevés de notes des étudiants.
--       Ne JAMAIS le rendre public (données personnelles).
insert into storage.buckets (id, name, public)
values ('documents', 'documents', false)
on conflict (id) do nothing;

-- l'étudiant upload uniquement dans son propre dossier (user_id/...)
drop policy if exists "documents_user_upload" on storage.objects;
create policy "documents_user_upload" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'documents'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- l'étudiant remplace/efface son fichier ; l'admin gère tout
drop policy if exists "documents_user_update" on storage.objects;
create policy "documents_user_update" on storage.objects
  for update to authenticated
  using (
    bucket_id = 'documents'
    and ((storage.foldername(name))[1] = auth.uid()::text or is_admin())
  );

drop policy if exists "documents_user_delete" on storage.objects;
create policy "documents_user_delete" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'documents'
    and ((storage.foldername(name))[1] = auth.uid()::text or is_admin())
  );

-- l'étudiant relit ses propres fichiers ; l'admin lit tout (signed URL)
drop policy if exists "documents_user_select" on storage.objects;
create policy "documents_user_select" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'documents'
    and ((storage.foldername(name))[1] = auth.uid()::text or is_admin())
  );

-- Recharge le cache de schéma PostgREST (sinon erreurs PGRST204 sur les nouvelles colonnes)
notify pgrst, 'reload schema';

-- ============================================================================
-- 12) CATÉGORIES (RUBRIQUES) PAR MATIÈRE
--     Avant : une seule table globale `categories` (id, label, icon, position)
--             => les mêmes onglets (Cours, TD, Examen…) pour TOUTES les matières.
--     Après : chaque matière a SES propres rubriques. Ce qui est demandé en
--             droit n'est pas ce qui est demandé en éco-gestion.
--     Clé : (univ, faculte, annee, matiere, cat_id). `cat_id` est la valeur
--           stockée dans contenus.type. Une matière sans rubrique => aucun onglet.
--     À exécuter tel quel : idempotent (sûr à relancer).
-- ============================================================================

-- 12.a) Si l'ancienne table globale existe encore (colonne `id`, pas de `matiere`),
--       on la renomme pour récupérer ses libellés/icônes lors du backfill.
do $$
begin
  if exists (
        select 1 from information_schema.columns
        where table_schema='public' and table_name='categories' and column_name='id'
      )
     and not exists (
        select 1 from information_schema.columns
        where table_schema='public' and table_name='categories' and column_name='matiere'
      )
  then
    -- on la sort d'abord de la publication realtime si elle y est
    begin
      alter publication supabase_realtime drop table categories;
    exception when others then null;
    end;
    alter table categories rename to categories_global_old;
  end if;
end $$;

-- 12.b) Nouvelle table scopée par matière.
create table if not exists categories (
  univ     text not null,
  faculte  text not null,
  annee    text not null,
  matiere  text not null,
  cat_id   text not null,                 -- valeur stockée dans contenus.type (ex. 'Cours')
  label    text not null,
  icon     text default '📄',
  position int  default 0,
  primary key (univ, faculte, annee, matiere, cat_id)
);

-- 12.c) Backfill : chaque matière récupère EXACTEMENT les rubriques que son
--       contenu utilise déjà, pour que rien ne disparaisse après migration.
--       Les libellés/icônes proviennent de l'ancienne table globale si dispo.
do $$
begin
  if exists (select 1 from information_schema.tables
             where table_schema='public' and table_name='categories_global_old') then
    insert into categories (univ, faculte, annee, matiere, cat_id, label, icon, position)
    select distinct c.univ, c.faculte, c.annee, c.matiere, c.type,
           coalesce(g.label, c.type), coalesce(g.icon, '📄'), coalesce(g.position, 0)
    from contenus c
    left join categories_global_old g on g.id = c.type
    where c.type is not null and c.univ is not null and c.faculte is not null
      and c.annee is not null and c.matiere is not null
    on conflict do nothing;
  else
    insert into categories (univ, faculte, annee, matiere, cat_id, label, icon, position)
    select distinct c.univ, c.faculte, c.annee, c.matiere, c.type,
           c.type, '📄', 0
    from contenus c
    where c.type is not null and c.univ is not null and c.faculte is not null
      and c.annee is not null and c.matiere is not null
    on conflict do nothing;
  end if;
end $$;

-- 12.d) RLS : lecture publique (les onglets sont visibles par tous), écriture admin only.
alter table categories enable row level security;

drop policy if exists categories_read on categories;
create policy categories_read on categories
  for select using (true);

drop policy if exists categories_admin_write on categories;
create policy categories_admin_write on categories
  for all using (is_admin()) with check (is_admin());

-- 12.e) Realtime : pour que l'ajout/suppression d'une rubrique se propage en direct.
do $$
begin
  alter publication supabase_realtime add table categories;
exception when duplicate_object then null; when others then null;
end $$;

-- Recharge le cache de schéma PostgREST
notify pgrst, 'reload schema';
