-- =====================================================================
--  MovieLens 32M  |  08_optimizer.sql : how the DBMS plans a query
--
--  The lecture notes on join trees, selectivity and cost estimation,
--  checked against a real optimizer on 32 million rows:
--    O1  Catalog statistics the optimizer reads (n_r, b_r, V(A,r), MCVs, histograms)
--    O2  Selectivity by hand vs the optimizer's estimate vs the true count
--    O3  Where the independence assumption breaks, and extended statistics fix it
--    O4  Join-size estimation and join ORDER: 4 relations, 24 left-deep / 120 trees
--    O5  Access paths: when an index is used, and when a full scan is cheaper
--    O6  Physical order: correlation, and why BRIN only works on clustered data
--    O7  Materialized aggregates: paying once instead of on every query
--
--  Everything runs inside BEGIN ... ROLLBACK: nothing is left behind.
--  EXPLAIN uses TIMING OFF: per-row timing on Windows distorts the
--  comparison (measured: it can make an index scan look slower than it is).
-- =====================================================================

\timing on
SET search_path TO movielens, public;
SET timezone = 'UTC';   -- years and dates of ratings are UTC (the dataset's clock)
BEGIN;

-- =====================================================================
-- O1. WHAT DOES THE OPTIMIZER KNOW?
-- n_r (tuples) and b_r (8 KB blocks) live in pg_class; V(A,r), the most
-- common values with their frequencies, equi-depth histograms and the
-- physical-order correlation live in pg_stats (built by ANALYZE from a
-- 30,000-row sample, default_statistics_target = 100).
-- =====================================================================

SELECT relname AS relation, reltuples::bigint AS n_r, relpages AS b_r,
       round(reltuples / nullif(relpages, 0)) AS f_r_tuples_per_block,
       pg_size_pretty(pg_relation_size(oid)) AS size
FROM pg_class
WHERE relnamespace = 'movielens'::regnamespace
  AND relname IN ('rating', 'movie', 'movie_genre', 'genre', 'ml_user', 'tag_application')
ORDER BY reltuples DESC;

-- V(A, rating): negative n_distinct means "this fraction of n_r" (it grows with the table)
SELECT attname AS attribute, n_distinct,
       CASE WHEN n_distinct < 0 THEN round(-n_distinct * (SELECT reltuples FROM pg_class WHERE oid = 'rating'::regclass))
            ELSE n_distinct END::bigint AS v_a_r_estimate,
       round(correlation::numeric, 3) AS correlation
FROM pg_stats
WHERE schemaname = 'movielens' AND tablename = 'rating'
ORDER BY attname;

-- The exact V(A, r) for comparison. count(DISTINCT ...) over 32M rows sorts
-- each column on disk (39 minutes on our laptop): exactly the work ANALYZE
-- avoids. The materialized views already hold one row per film and per user.
-- On this data the sample UNDER-estimates V(movie_id) ~11x and V(user_id)
-- ~6x: a 30,000-row sample sees few of the 84K films' long tail.
SELECT (SELECT count(*) FROM mv_movie_stats)                 AS v_movie_id,
       (SELECT count(*) FROM mv_user_stats)                  AS v_user_id,
       (SELECT count(*) FROM (SELECT DISTINCT stars FROM rating) s) AS v_stars;

-- The MCV list for stars: value → frequency (here every value is "common")
SELECT v.val AS stars, round(v.freq::numeric, 4) AS mcv_freq
FROM pg_stats s,
     unnest(s.most_common_vals::text::numeric[], s.most_common_freqs) AS v(val, freq)
WHERE s.schemaname = 'movielens' AND s.tablename = 'rating' AND s.attname = 'stars'
ORDER BY v.val;


-- =====================================================================
-- O2. SELECTIVITY: HAND vs OPTIMIZER vs TRUTH
-- (a) σ_stars=5.0 : selectivity = MCV frequency of 5.0
-- (b) σ_rated_at ≥ 2020-01-01 : equi-depth histogram, 100 buckets each
--     holding ~1% of rows; selectivity = (buckets above the constant +
--     linear share of the bucket that contains it) / 100
-- =====================================================================

-- (a) by hand
SELECT round(f.freq * c.reltuples) AS hand_estimate
FROM pg_class c,
     (SELECT v.freq FROM pg_stats s,
             unnest(s.most_common_vals::text::numeric[], s.most_common_freqs) AS v(val, freq)
      WHERE s.schemaname = 'movielens' AND s.tablename = 'rating' AND s.attname = 'stars'
        AND v.val = 5.0) f
WHERE c.oid = 'rating'::regclass;
-- optimizer (rows=...) and truth (actual rows=...)
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY OFF) SELECT * FROM rating WHERE stars = 5.0;

-- (b) by hand, from the histogram bounds
WITH h AS (
    SELECT array_length(b, 1) - 1 AS buckets, b
    FROM (SELECT histogram_bounds::text::timestamptz[] AS b FROM pg_stats
          WHERE schemaname = 'movielens' AND tablename = 'rating' AND attname = 'rated_at') x
), k AS (                            -- the bucket i with b[i] <= constant < b[i+1]
    SELECT h.*, max(i) AS i FROM h, generate_series(1, h.buckets) i
    WHERE h.b[i] <= '2020-01-01'::timestamptz GROUP BY h.buckets, h.b
)
SELECT round(((buckets - i)                                              -- whole buckets above
              + extract(epoch FROM b[i + 1] - '2020-01-01'::timestamptz)
              / extract(epoch FROM b[i + 1] - b[i]))                    -- part of bucket i
             / buckets * (SELECT reltuples FROM pg_class WHERE oid = 'rating'::regclass)) AS hand_estimate
FROM k;
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY OFF) SELECT * FROM rating WHERE rated_at >= '2020-01-01';


-- =====================================================================
-- O3. THE INDEPENDENCE ASSUMPTION
-- For σ_p∧q the optimizer multiplies: sel(p ∧ q) = sel(p) × sel(q).
-- Half stars did not exist before 2003 (BR-3), so "a half-star rating
-- before 2003" is truly empty, yet the product of two healthy
-- selectivities predicts 3.3 million rows: 31% half stars (MCV list) ×
-- 1/3, the built-in default for an inequality on an expression that has
-- no statistics at all. Two lessons: independence, and default guesses.
-- Extended statistics keep a joint MCV list of (stars, year) pairs. The
-- pair has ~10 × 29 = 290 values, so the list must be longer than the
-- default 100 entries, or the missing pairs get a residual guess.
-- =====================================================================

EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY OFF)
SELECT * FROM rating
WHERE stars IN (0.5, 1.5, 2.5, 3.5, 4.5) AND extract(year FROM rated_at) < 2003;

CREATE STATISTICS st_stars_year (mcv) ON stars, (extract(year FROM rated_at)) FROM rating;
ALTER STATISTICS st_stars_year SET STATISTICS 1000;
ANALYZE rating;

EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY OFF)
SELECT * FROM rating
WHERE stars IN (0.5, 1.5, 2.5, 3.5, 4.5) AND extract(year FROM rated_at) < 2003;


-- =====================================================================
-- O4. JOIN SIZE AND JOIN ORDER
-- Estimated size of r ⋈ s on A:  n_r · n_s / max(V(A,r), V(A,s))
-- The 4-relation query below has 4! = 24 left-deep orders and
-- (2(N−1))!/(N−1)! = 6!/3! = 120 binary join trees. PostgreSQL searches
-- them by dynamic programming (System R style) up to geqo_threshold
-- relations; beyond that, a genetic algorithm.
-- =====================================================================

SHOW geqo_threshold;
SHOW join_collapse_limit;

-- Join-size estimate for rating ⋈ movie by hand. V(movie_id, rating) = rows of
-- mv_movie_stats; V(movie_id, movie) = n_movie (it is the key). FK join: the
-- estimate should come out as n_rating, since every rating finds one movie.
SELECT r.reltuples::bigint AS n_rating, m.reltuples::bigint AS n_movie,
       (SELECT count(*) FROM mv_movie_stats) AS v_movie_id_rating,
       round(r.reltuples * m.reltuples
             / greatest((SELECT count(*) FROM mv_movie_stats), m.reltuples)) AS hand_estimate
FROM pg_class r, pg_class m
WHERE r.oid = 'rating'::regclass AND m.oid = 'movie'::regclass;
EXPLAIN SELECT * FROM rating r JOIN movie m USING (movie_id);

-- "How did 2020's raters score film noir?" (truth: 35,234 ratings)
-- (1) Default settings. The optimizer starts from σ_genre='Film-Noir'(genre)
-- and probes ix_rating_movie once per noir film (index nested loop).
-- On our laptop this is the SLOWEST plan (~10 s): rating is stored in
-- user order, so each film's ratings are scattered (correlation ≈ 0,
-- see O1) and the probes fetch ~300K random pages, more than the 204K
-- pages of a full scan. The cost model priced those pages as mostly
-- cached because effective_cache_size says 4 GB of cache.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON)
SELECT count(*), round(avg(r.stars), 3)
FROM rating r
JOIN movie m        ON m.movie_id = r.movie_id
JOIN movie_genre mg ON mg.movie_id = m.movie_id
JOIN genre g        ON g.genre_id = mg.genre_id
WHERE g.genre_name = 'Film-Noir' AND r.rated_at >= '2020-01-01';

-- (2) Tell the truth about the machine (8 GB RAM, 128 MB shared_buffers):
-- the same optimizer now chooses one sequential scan of rating, hash-joined
-- to the 353 noir films found from genre first. ~4 s, same answer.
SET LOCAL effective_cache_size = '512MB';
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON)
SELECT count(*), round(avg(r.stars), 3)
FROM rating r
JOIN movie m        ON m.movie_id = r.movie_id
JOIN movie_genre mg ON mg.movie_id = m.movie_id
JOIN genre g        ON g.genre_id = mg.genre_id
WHERE g.genre_name = 'Film-Noir' AND r.rated_at >= '2020-01-01';
RESET effective_cache_size;

-- (3) Same query, but the optimizer must follow the written order:
-- ((rating ⋈ movie) ⋈ movie_genre) ⋈ genre, a left-deep tree whose
-- intermediate results hold 4.6M and then 12.8M rows (vs 353 noir films
-- in plan 2) before the selective genre filter applies. Compare the
-- "actual rows" of the join nodes, not just the time.
SET LOCAL join_collapse_limit = 1;
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON)
SELECT count(*), round(avg(r.stars), 3)
FROM rating r
JOIN movie m        ON m.movie_id = r.movie_id
JOIN movie_genre mg ON mg.movie_id = m.movie_id
JOIN genre g        ON g.genre_id = mg.genre_id
WHERE g.genre_name = 'Film-Noir' AND r.rated_at >= '2020-01-01';
RESET join_collapse_limit;


-- =====================================================================
-- O5. ACCESS PATHS: INDEX OR FULL SCAN?
-- ix_rating_movie (movie_id). For one obscure film the index wins; for
-- the most-rated film (~100K rows spread over the whole table) a bitmap
-- scan; for a value matching a quarter of the table, a sequential scan.
-- The optimizer decides from the selectivity estimate, not from a rule.
-- =====================================================================

EXPLAIN (COSTS ON) SELECT avg(stars) FROM rating WHERE movie_id = 3000;          -- a mid-tail film
EXPLAIN (COSTS ON) SELECT avg(stars) FROM rating
                   WHERE movie_id = (SELECT movie_id FROM mv_movie_stats ORDER BY n_ratings DESC LIMIT 1);
EXPLAIN (COSTS ON) SELECT avg(stars) FROM rating WHERE stars = 4.0;

-- The PK (user_id, movie_id) serves "user 1's ratings" (leading column) …
EXPLAIN (COSTS ON) SELECT count(*) FROM rating WHERE user_id = 1;
-- … but not "movie 1's ratings" without ix_rating_movie: drop it and look
DROP INDEX ix_rating_movie;
EXPLAIN (COSTS ON) SELECT avg(stars) FROM rating WHERE movie_id = 3000;


-- =====================================================================
-- O6. PHYSICAL ORDER: CORRELATION AND BRIN
-- ratings.csv is sorted by user, so rated_at is scattered over the file
-- (correlation ≈ 0, see O1). A BRIN index stores only min/max per block
-- range: tiny, but useless unless the column follows the physical order.
-- A 10% sample stored twice: in user order and in time order.
-- =====================================================================

CREATE TEMP TABLE r_user_order AS SELECT * FROM rating WHERE user_id % 10 = 0 ORDER BY user_id, movie_id;
CREATE TEMP TABLE r_time_order AS SELECT * FROM r_user_order ORDER BY rated_at;
CREATE INDEX ON r_user_order USING brin (rated_at);
CREATE INDEX ON r_time_order USING brin (rated_at);
CREATE INDEX bt_time ON r_time_order (rated_at);
ANALYZE r_user_order; ANALYZE r_time_order;

SELECT c.relname AS index_name, pg_size_pretty(pg_relation_size(c.oid)) AS size
FROM pg_class c JOIN pg_index i ON i.indexrelid = c.oid
WHERE i.indrelid IN ('r_user_order'::regclass, 'r_time_order'::regclass);

SELECT tablename, round(correlation::numeric, 3) AS rated_at_correlation
FROM pg_stats WHERE tablename IN ('r_user_order', 'r_time_order') AND attname = 'rated_at';

DROP INDEX bt_time;                  -- compare BRIN against BRIN
EXPLAIN (ANALYZE, TIMING OFF, COSTS OFF, SUMMARY ON)
SELECT count(*) FROM r_user_order WHERE rated_at >= '2023-06-01';
EXPLAIN (ANALYZE, TIMING OFF, COSTS OFF, SUMMARY ON)
SELECT count(*) FROM r_time_order WHERE rated_at >= '2023-06-01';


-- =====================================================================
-- O7. MATERIALIZED AGGREGATES
-- Top-10 films by Bayesian average: from the 32M-row base table every time,
-- or from mv_movie_stats (84K rows, refreshed once per load).
-- =====================================================================

EXPLAIN (ANALYZE, TIMING OFF, COSTS OFF, SUMMARY ON)
SELECT movie_id, (50 * 3.54 + sum(stars)) / (50 + count(*)) AS bayes
FROM rating GROUP BY movie_id ORDER BY bayes DESC LIMIT 10;

EXPLAIN (ANALYZE, TIMING OFF, COSTS OFF, SUMMARY ON)
SELECT movie_id, (50 * 3.54 + mean_stars * n_ratings) / (50 + n_ratings) AS bayes
FROM mv_movie_stats ORDER BY bayes DESC LIMIT 10;

ROLLBACK;
