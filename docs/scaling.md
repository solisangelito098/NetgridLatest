# Scaling NetGrid — operator playbook

This document covers the moving parts when growing the network past the
"a few dozen blogs" comfort zone, all the way to the **3,000-3,500 site**
peptide network target. Read end-to-end before you onboard the next 500
blogs.

---

## 1. Capacity model

Each post takes ~25-35 seconds end-to-end (Claude content + Claude scene +
2× Nano Banana images + scrubber + Shopify Files upload). Auto-publish
runs sequentially inside one cron tick, so:

| Setup | Capacity (posts / hour) | Capacity (posts / day) |
|---|---|---|
| 1 shard, hourly, 300s maxDuration | ~10 | ~240 |
| 1 shard, hourly, **600s maxDuration** | ~16-20 | ~480 |
| **4 shards** × hourly × 600s          | ~60-80 | ~1,500-1,900 |

For 3,500 blogs on a weekly cadence the daily average is ~500 posts/day,
with bursts up to ~1,500/day if many blogs share the same configured
posting day. The 4-shard configuration in `render.yaml` is what gets you
there.

---

## 2. Sharding — how it works

`render.yaml` defines four parallel cron services:

```
netgrid-cron-auto-publish-0   CRON_PATH=/api/cron/auto-publish?shard=0&shardCount=4
netgrid-cron-auto-publish-1   CRON_PATH=/api/cron/auto-publish?shard=1&shardCount=4
netgrid-cron-auto-publish-2   CRON_PATH=/api/cron/auto-publish?shard=2&shardCount=4
netgrid-cron-auto-publish-3   CRON_PATH=/api/cron/auto-publish?shard=3&shardCount=4
```

Each cron service fires hourly and curls the web service with its
shard params. Inside `runAutoPublishCron`:

```ts
shardForBlog(blog.id, shardCount) === shardIndex
```

Same blog → same shard, forever (SHA1 hash of blog UUID mod 4). The four
shards are disjoint — no two ever process the same blog — so there's no
risk of double-posting even though they all fire at the top of every
hour.

**Why not more than 4?** Each cron service adds Render cost (~$1-5/mo
each) and each shard is bottlenecked by the same web service compute,
not by the cron container. 4 is the sweet spot: fits within the
Anthropic free-tier rate limits (~50 RPM with 4 parallel runs), gives
~2× throughput headroom over 3,500-blog peak demand, and stays cheap.

If you need more, edit `render.yaml`:
1. Duplicate one of the `netgrid-cron-auto-publish-N` blocks
2. Change the name + `shard=N` query param
3. Update **every** existing shard's `shardCount` to the new total
4. Redeploy

---

## 3. Adding new blogs — incremental ops

Each new blog is just a row insert in the `blogs` table. No code, no
migration, no cron restart needed.

When you onboard a batch (~200-500 blogs at a time):

1. **Insert the rows** — manual via the admin UI, or bulk via the CSV
   importer at `/blogs?import=1`.
2. **Verify the style profile assigned** — peptide blogs should have a
   row in `style_profiles` immediately. SQL:
   ```sql
   SELECT b.domain, sp.voice_id, sp.skeleton_id, sp.min_hamming_at_assign
   FROM blogs b
   LEFT JOIN style_profiles sp ON sp.blog_id = b.id
   WHERE b.client_id = '<client-uuid>'
   ORDER BY b.created_at DESC LIMIT 50;
   ```
   `min_hamming_at_assign` should be ≥ 5.0 for fresh blogs — under that
   means the assignment algorithm couldn't find enough diversity vs.
   the existing network.
3. **Set posting cadence** — `posting_frequency_days` array of ISO
   weekdays (1=Mon ... 7=Sun). e.g. `[2,5]` for Tue+Fri.
4. **Set status to `active`** — the cron only considers active blogs.
5. **Watch the next cron run** — should see new blogs in the
   `auto-publish` cron response.

---

## 4. Monitoring at scale

### Things to watch on the daily cron run

```bash
curl -fsS -H "Authorization: Bearer $CRON_SECRET" \
  "https://<render-url>/api/cron/auto-publish?shard=0&shardCount=4" | jq
```

Look at:

| Field | Healthy range | What "off" looks like |
|---|---|---|
| `considered` | rises with network size | flat → DB select is broken |
| `due` | a fraction of `considered`, varies by day | always 0 → posting days never match, or all blogs in safety floor |
| `published` | close to `due`, capped by `maxPerRun` | much lower → look at `results[].status=="failed"` per blog |
| `failed` | should be < 5% of attempts | spiking → check API rate limits, image upload, scrubber rejections |
| `deferred` | 0 unless the network outgrew current shard count | rising → time to add a shard |

### SQL spot checks

**Posts published yesterday by client:**
```sql
SELECT c.name, COUNT(*) AS posts
FROM generated_posts gp
JOIN clients c ON c.id = gp.client_id
WHERE gp.status = 'published'
  AND gp.published_at >= NOW() - INTERVAL '24 hours'
GROUP BY c.name
ORDER BY posts DESC;
```

**Blogs behind schedule:**
```sql
SELECT domain, last_post_verified_at,
       NOW() - last_post_verified_at AS days_since
FROM blogs
WHERE status = 'active'
  AND last_post_verified_at < NOW() - INTERVAL '7 days'
ORDER BY last_post_verified_at ASC
LIMIT 50;
```

**Active blogs without a style profile** (peptide blogs that never got
one assigned):
```sql
SELECT b.id, b.domain
FROM blogs b
LEFT JOIN style_profiles sp ON sp.blog_id = b.id
JOIN clients c ON c.id = b.client_id
WHERE b.status = 'active'
  AND c.niche = 'peptides'
  AND sp.id IS NULL;
```

---

## 5. API rate limits — what to request when

| Service | Default | When to upgrade |
|---|---|---|
| **Anthropic Claude** | 50 RPM, 40K input/min | At ~600 sites publishing daily. Free upgrade via support ticket. |
| **Google Nano Banana** | 60 RPM | At ~800 sites publishing daily. Upgrade auto-applies with paid plan. |
| **NewsAPI.org** | 100 req/day | Never at current usage (84/week). |
| **GNews** | 100 req/day | Never at current usage. |
| **Shopify Admin API** | 2 req/sec **per shop** | Never — each blog is its own shop. |
| **Shopify Files (GraphQL)** | shared with Admin API | Never at current usage. |
| **PageSpeed Insights** | 240 RPM | Never — SEO scan runs 1 blog at a time. |

---

## 6. Database growth

After 12 months at 500 posts/day:

| Table | Approx rows | Action |
|---|---|---|
| `blogs` | 3,500 | none |
| `clients` | <50 | none |
| `style_profiles` | 3,500 | none |
| `generated_posts` | ~180K | none until ~500K — then add a yearly archive table |
| `news_items` | <10K (30-day TTL) | none (auto-pruned) |
| `seo_scans` | scan-count × blogs | run a monthly purge of scans older than 90 days |
| `seo_issues` | high — every scan adds rows | same as above |
| `activity_log` | high | run a monthly purge of entries older than 180 days |

Add these as cron jobs when row counts cross 500K.

---

## 7. Render service tiers

At 3,500 sites you'll need:

| Service | Tier | Monthly cost (approx) |
|---|---|---|
| `netgrid` web service | Standard | $25 |
| `netgrid-cron-seo-scan` | tiny | $1-3 |
| `netgrid-cron-post-verification` | tiny | $1-3 |
| `netgrid-cron-monthly-reports` | tiny | $1-3 |
| `netgrid-cron-refresh-news` | tiny | $1-3 |
| `netgrid-cron-auto-publish-0` | tiny | $1-5 |
| `netgrid-cron-auto-publish-1` | tiny | $1-5 |
| `netgrid-cron-auto-publish-2` | tiny | $1-5 |
| `netgrid-cron-auto-publish-3` | tiny | $1-5 |
| **Total** | | **~$45-75/mo** |

Database (Neon) is separate — likely Neon Pro at ~$19/mo for the compute
+ storage at this volume.

---

## 8. Verifying the cron stack on Render

After deploying `render.yaml` changes:

1. Open **Render Dashboard → your team → All services**
2. Confirm these 9 services exist:
   - `netgrid` (web)
   - `netgrid-cron-seo-scan`
   - `netgrid-cron-post-verification`
   - `netgrid-cron-monthly-reports`
   - `netgrid-cron-refresh-news`
   - `netgrid-cron-auto-publish-0`
   - `netgrid-cron-auto-publish-1`
   - `netgrid-cron-auto-publish-2`
   - `netgrid-cron-auto-publish-3`
3. Click each cron service → **Events** tab → verify recent successful runs
4. For auto-publish, click into **Logs** of one of the shards — look for:
   ```
   [auto-publish] shard 1/4 — 875 of 3500 active blogs assigned to this shard
   [auto-publish] hour=14h UTC, considered=875, eligible=23, running=20, deferred=3, skipped=852
   [auto-publish] run order: 1. blog.example.com (slot=2h, lastPost=2026-05-12T14:00:00Z) | 2. ...
   ```

If the shard line is missing → SHARD params didn't reach the route.
Check the cron service env var `CRON_PATH` includes `?shard=N&shardCount=4`.

---

## 9. Emergency stops

**Pause auto-publish without code changes:**
1. Render Dashboard → each `netgrid-cron-auto-publish-N` service
2. **Suspend** the cron from the service settings
3. Resume the same way when ready

**Pause a single client's posting:**
```sql
UPDATE blogs SET status = 'paused' WHERE client_id = '<uuid>';
```

**Pause one blog:**
```sql
UPDATE blogs SET status = 'paused' WHERE id = '<uuid>';
```

The cron filters on `status = 'active'`, so paused blogs are invisible to
it until you flip them back.
