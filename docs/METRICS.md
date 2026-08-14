# FLIM metrics

Paste-ready SQL for the Supabase dashboard. Every query here was run against production on
2026-08-14 and returned sensible numbers; none of them write anything.

Save each one as its own snippet in the SQL Editor (the Management API can read saved snippets but
cannot create them, so this has to be done by hand once).

---

## 1. Activation funnel

**Read the caveat before the numbers.** Every activation event started logging on a different day:

| event | logging since |
|---|---|
| `post_shared`, `first_shot` | 2026-07-02 |
| `roll_joined`, `roll_created` | 2026-07-12 |
| `invite_redeemed` | 2026-07-24 |
| `reveal_watched` | 2026-08-03 |
| `first_launch` | 2026-08-10 |
| `onboarding_finished`, `camera_authorized` | 2026-08-12 |

Comparing raw counts across them is meaningless: `first_launch` is not everyone who ever launched,
it is four days' worth. The funnel therefore has to be scoped to users who joined AFTER the newest
event shipped. **Move the date forward whenever a new event is added.**

```sql
WITH cohort AS (
  SELECT id FROM public.users WHERE created_at >= '2026-08-12'
), steps(step, ord) AS (VALUES
  ('first_launch',1),('onboarding_finished',2),('camera_authorized',3),
  ('first_shot',4),('roll_joined',5),('post_shared',6),('reveal_watched',7))
SELECT s.step,
       count(DISTINCT a.user_id) AS reached,
       (SELECT count(*) FROM cohort) AS cohort_size
FROM steps s
LEFT JOIN public.activation_events a
       ON a.event = s.step AND a.user_id IN (SELECT id FROM cohort)
GROUP BY s.step, s.ord
ORDER BY s.ord;
```

## 2. Roll health

Rolls are the product. A roll with one member is a failed roll.

```sql
SELECT count(*) AS rolls,
       count(*) FILTER (WHERE members > 1) AS shared,
       count(*) FILTER (WHERE members = 1) AS solo,
       round(avg(members), 1) AS avg_members
FROM (SELECT r.id, count(m.user_id) AS members
      FROM public.rolls r
      LEFT JOIN public.roll_members m ON m.roll_id = r.id
      GROUP BY r.id) t;
```

## 3. Reveal conversion

The reveal is the hook. This separates "nobody watches it" from "nobody gets the chance", which are
completely different problems. As of 2026-08-14 it was the second: 3 of 4 people who had a roll
develop since logging began watched it. The bottleneck is roll creation, not the reveal.

```sql
SELECT
  (SELECT count(DISTINCT m.user_id)
     FROM public.roll_members m
     JOIN public.rolls r ON r.id = m.roll_id
    WHERE r.created_at + interval '12 hours' BETWEEN '2026-08-03' AND now()) AS could_have_watched,
  (SELECT count(DISTINCT user_id)
     FROM public.activation_events
    WHERE event = 'reveal_watched') AS did_watch;
```

`rolls` has no reveal column; the reveal time is `created_at + 12 hours`, computed client side
(`Roll.developDelay`). If that constant changes, change it here.

## 4. Push reach

Gates the whole reveal loop: no notification, no reveal. Watch this after 1.4.1 reaches people. If
it does not climb, the notification recovery is not working.

```sql
SELECT count(*) AS users,
       count(*) FILTER (WHERE t.user_id IS NOT NULL) AS with_token,
       round(100.0 * count(*) FILTER (WHERE t.user_id IS NOT NULL) / count(*), 1) AS pct
FROM public.users u
LEFT JOIN (SELECT DISTINCT user_id FROM public.device_tokens) t ON t.user_id = u.id;
```

## 5. Retention by signup cohort

```sql
SELECT to_char(date_trunc('week', u.created_at), 'YYYY-MM-DD') AS cohort,
       count(DISTINCT u.id) AS joined,
       count(DISTINCT p.user_id) FILTER (WHERE p.taken_at > now() - interval '7 days') AS shot_this_week
FROM public.users u
LEFT JOIN public.photos p ON p.user_id = u.id
GROUP BY 1 ORDER BY 1;
```

## 6. Storage per person

Storage paths are `<user_id>/<photo_id>.jpg`, so the first segment attributes exactly.

```sql
SELECT u.username,
       count(*) AS objects,
       round((sum((o.metadata->>'size')::bigint) / 1048576.0)::numeric, 1) AS mb
FROM storage.objects o
JOIN public.users u ON u.id = split_part(o.name, '/', 1)::uuid
WHERE o.bucket_id = 'photos'
GROUP BY u.username
ORDER BY 3 DESC;
```

## 7. Storage summary

**Use the median, not the mean.** On 2026-08-14 the mean was 31 MB and the median 8.5 MB, because
one account held 28% of the bucket and 10 of 38 accounts had uploaded nothing.

```sql
WITH per_user AS (
  SELECT split_part(name, '/', 1) AS uid,
         sum((metadata->>'size')::bigint) / 1048576.0 AS mb
  FROM storage.objects WHERE bucket_id = 'photos' GROUP BY 1)
SELECT (SELECT count(*) FROM public.users) AS users,
       count(*) AS uploaders,
       round(sum(mb)::numeric, 0) AS total_mb,
       round((sum(mb) / (SELECT count(*) FROM public.users))::numeric, 1) AS mean_per_user,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY mb)::numeric, 1) AS median_per_uploader,
       round(max(mb)::numeric, 1) AS largest
FROM per_user;
```

## 8. Egress proxy

**This is modelled, not measured.** Real egress is bytes served and lives in Supabase's logs, not in
Postgres; nothing in the database records a download. This computes each person's card bytes times
their audience: what a single full pass would cost if every follower viewed every post once.

Treat it as a RANKING of who drives cost, not an absolute figure. It ignores caching, and signed
URLs are cached on device and at the CDN, so real repeat views often cost nothing.

```sql
SELECT u.username,
       count(DISTINCT p.id) AS posts,
       (SELECT count(*) FROM public.follows f WHERE f.following_id = u.id) AS followers,
       round((sum((o.metadata->>'size')::bigint) / 1048576.0)::numeric, 2) AS card_mb,
       round((sum((o.metadata->>'size')::bigint) / 1048576.0
              * greatest((SELECT count(*) FROM public.follows f WHERE f.following_id = u.id), 1))::numeric, 1)
         AS mb_per_pass
FROM public.posts p
JOIN public.users u ON u.id = p.user_id
JOIN public.photos ph ON ph.id = p.photo_id
JOIN storage.objects o ON o.name = ph.feed_path AND o.bucket_id = 'photos'
GROUP BY u.id, u.username
ORDER BY 5 DESC;
```

Storage and egress are driven by DIFFERENT people, which is the point of running both: the heaviest
uploader can be a minor egress cost if few people follow them, and vice versa.

## 9. Invite loop

The only growth engine while the app is invite only.

```sql
SELECT
  (SELECT count(DISTINCT user_id) FROM public.activation_events WHERE event = 'invite_sent') AS sent,
  (SELECT count(DISTINCT user_id) FROM public.activation_events WHERE event = 'invite_redeemed') AS redeemed;
```

## 10. Missing renditions

A photo with no card falls back to the ~1000 kB master everywhere, including grids. This was 9% in
early August and is now under 5% and still healing; if it starts climbing again, `uploadRenditions`
is failing more often than it is being repaired.

```sql
SELECT count(*) AS total,
       count(*) FILTER (WHERE feed_path IS NULL) AS no_card,
       count(*) FILTER (WHERE thumb_path IS NULL) AS no_thumb,
       round(100.0 * count(*) FILTER (WHERE feed_path IS NULL) / count(*), 1) AS pct_no_card
FROM public.photos;
```

## 11. Push pipeline health

Every table the push function polls should sit at zero unsent. A number that stays high means the
cron is not running or the function is erroring.

```sql
SELECT 'post_comments' AS t, count(*) FILTER (WHERE NOT push_sent) AS unsent FROM public.post_comments
UNION ALL SELECT 'post_reactions', count(*) FILTER (WHERE NOT push_sent) FROM public.post_reactions
UNION ALL SELECT 'posts',          count(*) FILTER (WHERE NOT push_sent) FROM public.posts
UNION ALL SELECT 'comment_likes',  count(*) FILTER (WHERE NOT push_sent) FROM public.comment_likes;
```
