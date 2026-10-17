# Offline de bout en bout — contrat app ↔ backend

App Zonik ≥ 1.2.0. Ce document décrit ce que fait l'app hors ligne et ce que le
backend (`pointage-saas`) doit faire pour en tirer parti. **L'app 1.2 marche
déjà avec le backend actuel** : tout ce qui est nouveau est soit rangé dans le
`payload` (JSONB libre), soit optionnel avec repli automatique.

## Ce que fait l'app

| Étape | Comportement |
|---|---|
| Pointage | Écrit en SQLite immédiatement, jamais bloqué par le réseau. Attaché à l'agent (tenant + matricule). |
| Heure | Heure du téléphone **+** horloge monotone Android (`elapsedRealtime`, non modifiable) **+** n° de démarrage. |
| Zone | Contrôle local contre les sites en cache (site de la vacation en cours, sinon le plus proche). Indicatif : PostGIS tranche. |
| Envoi | Lots de 10 max et ~1,2 Mo de photos max, délai adapté au nombre de photos. Seuls les pointages de l'agent connecté, avec SON token (figé pour toute la passe, même si un autre agent se connecte pendant l'envoi). |
| Échec réseau / 5xx / 408 / 429 | Backoff exponentiel par pointage (30 s → 30 min, ±20 %). Bouton « Envoyer » = forcé. |
| 400/422 (JSON de l'API) sur un lot | Lot coupé en deux jusqu'à isoler le pointage fautif ; lui seul est marqué refusé (motif affiché, bouton « Renvoyer »). |
| 409 sur un pointage seul | Déjà connu du serveur : marqué envoyé. |
| 413 sur un pointage seul | Renvoyé sans photo plutôt que perdu. |
| 401 / 403 | Sync suspendue, bandeau « Session expirée », pointages intacts ; ils partent dès la reconnexion. |
| 404, page HTML (portail captif, proxy) | Temporaire : backoff, jamais de refus. |
| Après envoi | Photo effacée du téléphone. Historique synchronisé purgé après 30 jours. |
| Planning / sites | Téléchargés (hier → J+7), lus uniquement depuis le cache : visibles une semaine sans réseau. |
| Déclencheurs | Lancement, retour au premier plan, retour du réseau, toutes les 2 min, après chaque pointage, connexion. |

## Ce qui part dans `POST /api/attendance/sync`

Corps inchangé (`{ punches: [...] }`), champs historiques inchangés. Nouveaux
champs, tous dans `payload` :

```json
{
  "clientUuid": "…", "type": "in", "method": "gps",
  "punchedAt": "2026-10-17T05:02:11.000Z",
  "payload": {
    "lat": -11.7022, "lng": 43.2551, "accuracy": 12.5,
    "faceScore": 0.71, "faceMatch": true, "photo": "<base64>",
    "device": {
      "elapsedMs": 81234567,   "bootCount": 412,      // au pointage
      "sentAt": "2026-10-17T09:40:00.000Z",
      "sentElapsedMs": 97900123, "sentBootCount": 412, // à l'envoi
      "clockOffsetMs": -1800,  // serveur − téléphone, mesuré à la dernière sync
      "autoTime": true,        // heure automatique activée
      "attempt": 3
    },
    "gps":  { "fixAt": "2026-10-17T05:02:09.000Z", "isMocked": false },
    "zone": { "siteId": "…", "distanceM": 42, "inZone": true }
  }
}
```

## À faire côté backend (par ordre d'impact)

### 1. Réponse par pointage — **prioritaire**
Traiter chaque pointage indépendamment et répondre **200** avec :

```json
{ "results": [
  { "clientUuid": "…", "status": "accepted" },
  { "clientUuid": "…", "status": "duplicate" },
  { "clientUuid": "…", "status": "rejected", "reason": "Agent désactivé" }
] }
```

`accepted`/`duplicate` → marqué envoyé ; `rejected` → refusé définitivement avec
le motif affiché à l'agent. **Chaque pointage du lot doit figurer dans
`results`** : un pointage absent ou au statut inconnu est renvoyé plus tard
(sans risque grâce à la dédup par `clientUuid`). Sans `results`, tout le lot
est accepté (comportement actuel). Ne renvoyer un 4xx global que si la requête
entière est invalide, et toujours en JSON `{ "message": "…" }` : une erreur 4xx
non-JSON est traitée comme un incident réseau.

### 2. Heure de confiance (anti-fraude)
Si `bootCount == sentBootCount` (pas de redémarrage entre pointage et envoi) :

```
punched_at_trusted = heure_reception_serveur − (sentElapsedMs − elapsedMs)
```

Précision : quelques secondes (latence réseau), même si l'agent a reculé
l'heure du téléphone. Sinon, repli sur `punchedAt + clockOffsetMs` (moins
fiable). Stocker les deux heures et la source (`monotonic` | `offset` |
`device`) ; signaler une anomalie si l'écart dépasse 5 min.

### 3. Signaux d'anomalie pour le dashboard
- `gps.isMocked = true` → position simulée (appli de faux GPS) ;
- `punchedAt − gps.fixAt > 10 min` → position périmée (fallback dernière position connue) ;
- `autoTime = false` et écart d'horloge important ;
- `zone.inZone = false` (à recouper avec le calcul PostGIS).

### 4. `GET /api/mobile/context?from=YYYY-MM-DD&to=YYYY-MM-DD`
Un seul appel au lieu de deux, pour les réseaux faibles. Tant qu'il renvoie 404,
l'app se replie sur `/api/scheduling/me/shifts` (sans cache des sites, sauf si
les vacations contiennent `site_lat`/`site_lng`/`site_radius_m`).

```json
{
  "serverTime": "2026-10-17T09:40:00.000Z",
  "sites":  [{ "id": "…", "name": "Siège Moroni", "lat": -11.7022, "lng": 43.2551, "radius_m": 150 }],
  "shifts": [{ "assignment_id": "…", "shift_id": "…", "starts_at": "…", "ends_at": "…",
               "site_id": "…", "site_name": "…", "post_name": "…", "role": "titulaire", "status": "planned" }]
}
```

`sites` = tous les sites où l'agent peut pointer (pour le gardiennage : tous
les sites du tenant, les agents tournent). La liste fournie **remplace** le
cache de l'app : un site supprimé ou un rayon modifié est pris en compte.

### 5. Réglages
- `express.json({ limit: '3mb' })` sur `/api/attendance/sync` (un lot ≈ 1,6 Mo en base64).
- Durée de vie du JWT agent longue (30 à 90 jours) : un agent hors ligne une semaine ne doit pas tomber en 401 au retour du réseau.
- L'en-tête HTTP `Date` (envoyé par défaut par Node) sert à mesurer le décalage d'horloge : ne pas le retirer au niveau de Caddy.

## Prochaines étapes côté app
1. Sync en arrière-plan app fermée (WorkManager), une fois la 1.2 validée sur téléphone.
2. Mode kiosque hors ligne (plusieurs agents sur un téléphone de site, PIN vérifié localement).
3. Cartes hors ligne des sites pour superviseurs / rondes.
