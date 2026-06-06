# Studia — projet complet

Plateforme d'entraide étudiante : cours, TD et examens corrigés, par abonnement, avec
tatouage QR anti-fuite traçable par abonné.

```
studia-complet/
├── index.html                     ← le site (front, à publier tel quel)
├── .env.example                   ← secrets serveur (modèle)
└── supabase/
    ├── schema.sql                 ← base + sécurité (RLS)
    └── functions/
        ├── create-checkout/       ← crée le paiement Stripe lié au compte
        ├── stripe-webhook/        ← active l'abonnement après paiement
        └── download/              ← téléchargement tatoué au nom de l'abonné
```

Le `index.html` **fonctionne déjà seul** en mode démo. Les étapes ci-dessous le rendent
réellement opérationnel : vrais comptes, vraie base, vrai paiement, protection forte.

---

## Prérequis
- Un compte **Supabase** (gratuit) et la **CLI** : `npm i -g supabase`
- Un compte **Stripe**
- Un hébergeur statique (**Netlify**, Vercel, Cloudflare Pages…)

---

## 1. Base de données
1. Crée un projet Supabase.
2. *SQL Editor* → colle et exécute `supabase/schema.sql`.
   - Si ta base existe déjà, ré-exécute le fichier : les `alter table … add column if not exists` ajoutent les nouveaux champs (`video_url`, `description`) sans casser l'existant.
3. *Storage* → crée un bucket **privé** nommé `sujets`.
4. *Authentication → Providers* → active **Email** (et **Google** si tu veux le bouton).
5. *Authentication → URL Configuration* → ajoute l'URL de ton site dans **Site URL** et **Redirect URLs** (sinon Google et la confirmation par email ne reviennent pas chez toi).
6. Note, dans *Project Settings → API* : `Project URL`, clé `anon public`, clé `service_role` (secrète).

## 2. Fonctions serveur (Edge Functions)
```bash
supabase login
supabase link --project-ref TON_REF        # le ref est dans l'URL du projet

# secrets (remplis d'abord .env à partir de .env.example)
supabase secrets set --env-file ./.env

# déploiement
supabase functions deploy create-checkout
supabase functions deploy download
supabase functions deploy stripe-webhook --no-verify-jwt   # Stripe appelle sans JWT
```
L'URL des fonctions est : `https://TON_REF.supabase.co/functions/v1`

## 3. Stripe
1. *Products* → crée « Abonnement Studia » avec 2 prix récurrents : **9 €/mois** et **39 €/semestre**.
   Récupère les `price_...` → mets-les dans les secrets `PRICE_MENSUEL` / `PRICE_SEMESTRE`.
2. *Developers → Webhooks* → « Add endpoint » :
   - URL : `https://TON_REF.supabase.co/functions/v1/stripe-webhook`
   - Événements : `checkout.session.completed`, `customer.subscription.updated`, `customer.subscription.deleted`
   - Copie le **Signing secret** (`whsec_...`) → secret `STRIPE_WEBHOOK_SECRET`.
3. Re-déploie après avoir mis les secrets : `supabase secrets set --env-file ./.env`.

## 4. Configurer le front
Ouvre `index.html`, en haut du `<script>`, remplis :
```js
const CONFIG={
  SUPABASE_URL:"https://TON_REF.supabase.co",
  SUPABASE_ANON_KEY:"eyJ... (anon public)",
  FUNCTIONS_URL:"https://TON_REF.supabase.co/functions/v1",
  // (les liens Payment Links restent un fallback optionnel)
  STRIPE_LINK_MENSUEL:"", STRIPE_LINK_SEMESTRE:"",
};
```

## 5. Publier
Renomme `index.html` si besoin, puis dépose-le sur Netlify (« Deploy manually »).
Mets cette URL dans le secret `SITE_URL`. C'est en ligne, en HTTPS.

---

## Comment tout s'enchaîne
1. L'étudiant s'inscrit (Supabase Auth) → reçoit un email de confirmation → confirme → est connecté.
2. Il clique « S'abonner » → `create-checkout` ouvre Stripe avec son `user.id` attaché.
3. Après paiement, Stripe appelle `stripe-webhook` → la table `subscribers` passe à `active`.
4. Grâce à la **RLS**, il voit alors le contenu payant (un non-abonné ne peut même pas le lire).
5. Quand il télécharge un sujet → `download` vérifie l'abonnement, récupère le fichier privé et
   **tatoue un QR mosaïque à son nom**. S'il fuite, la console admin (scan caméra / photo) dit qui.

## Gérer le catalogue (admin)
Connecte-toi avec l'email admin (`djad@studia.app` par défaut, à changer dans la RLS et `ADMIN_EMAIL`).
Dans **Console → Université → Filière → Niveau → Matière** :
- **+ Nouveau contenu** : formulaire pour créer un cours / TD / examen avec **URL vidéo** (YouTube ou Vimeo), tuteur, note, durée, description, et toggle "gratuit".
- **Dépose un fichier (PDF / image)** : envoie l'original dans le bucket privé `sujets`, génère un QR de tatouage de prévisualisation, et insère la ligne en base. Les téléchargements abonnés passent ensuite par l'edge function `download` qui tatoue à leur nom.
- Tous les champs (titre, tuteur, note, durée, URL vidéo, gratuit) sont éditables en place et auto-sauvegardés en base (débounce 600 ms).
- **Supprimer** efface la ligne et le fichier du bucket.

L'étudiant voit les contenus selon la RLS : gratuits visibles par tous, payants visibles uniquement par les abonnés actifs.

## Protection — les 4 couches
1. **RLS** : barrière réelle côté base (le floutage front n'est que cosmétique).
2. **Bucket privé** : aucun fichier en accès public ; tout passe par `download`.
3. **QR par-abonné** au moment du téléchargement (mosaïque non recadrable).
4. **Secrets côté serveur uniquement**.

## À ne jamais faire
- ❌ Mettre `STRIPE_SECRET_KEY` ou `SUPABASE_SERVICE_ROLE_KEY` dans `index.html`.
- ❌ Rendre le bucket `sujets` public.
- ❌ Diffuser des sujets/corrigés officiels de profs (seul le contenu **original** des tuteurs protège juridiquement).

## Notes / limites
- La fonction `download` traite les **PDF**. Pour tatouer aussi des **images**, ajoute une branche
  qui dessine le QR sur un canvas (même logique que l'admin côté front) — squelette facile à reprendre.
- Le code des fonctions est **prêt à déployer** mais n'a pas été exécuté dans ton environnement :
  teste avec `supabase functions serve` puis avec une vraie clé de test Stripe avant de passer en live.
- Admin : l'email admin est codé dans la RLS (`djad@studia.app`) et dans `index.html`. Change-le partout.
