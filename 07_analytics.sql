-- =====================================================================
--  MovieLens 32M  |  Analytics: SQL statistics, a recommender, k-means segments
--
--  A1-A9   research statistics computed INSIDE PostgreSQL
--  R1-R2   an item-to-item recommender built and evaluated in SQL
--  v_user_features   one row per user, the k-means input
--  segment / user_segment   k-means labels, written back by
--                           analytics/movielens_kmeans.ipynb
--  S1-S2   questions that need the segments
--
--  The notebook runs each labelled query from this file, so the SQL on
--  the slides and the SQL executed are the same text.
--  Re-runnable: views are dropped and recreated; segment tables are kept;
--  recommender tables are rebuilt by build_recommender().
-- =====================================================================

SET search_path TO movielens, public;
SET timezone = 'UTC';   -- years and dates of ratings are UTC (the dataset's clock)
SET client_min_messages = warning;
SET work_mem = '256MB';

-- The moment MovieLens switched to half stars (BR-3), read from the scale table
CREATE OR REPLACE FUNCTION half_star_switch() RETURNS timestamptz LANGUAGE sql STABLE AS
$$ SELECT valid_from FROM rating_scale WHERE scale_code = 'HALF' $$;


-- =====================================================================
-- A1. HOW UNEQUAL IS ATTENTION?
-- Share of all ratings that go to the top 1% / 10% of films, the share of
-- films with fewer than 10 ratings, and the Gini coefficient of ratings
-- per film (0 = every film equally rated, 1 = one film gets everything).
-- Gini on sorted x_1..x_n:  2·Σ i·x_i / (n·Σ x_i) − (n + 1)/n
-- =====================================================================

WITH s AS (
    SELECT n_ratings,
           row_number() OVER (ORDER BY n_ratings)      AS i_asc,
           row_number() OVER (ORDER BY n_ratings DESC) AS i_desc,
           count(*) OVER ()                            AS n,
           sum(n_ratings) OVER ()                      AS total
    FROM mv_movie_stats
)
SELECT max(n)                                                                        AS films_rated,
       max(total)                                                                    AS ratings,
       round(100.0 * sum(n_ratings) FILTER (WHERE i_desc <= 0.01 * n) / max(total), 1) AS top1pct_share,
       round(100.0 * sum(n_ratings) FILTER (WHERE i_desc <= 0.10 * n) / max(total), 1) AS top10pct_share,
       round(100.0 * count(*) FILTER (WHERE n_ratings < 10) / max(n), 1)             AS films_under_10_ratings_pct,
       round(2.0 * sum(i_asc * n_ratings) / (max(n) * max(total)) - (max(n) + 1.0) / max(n), 3) AS gini
FROM s;


-- =====================================================================
-- A2. DID HALF STARS CHANGE HOW PEOPLE RATE? (a natural experiment)
-- MovieLens added half stars in February 2003. Three views of it:
--  (a) the star distribution before and after;
--  (b) within-user change for users who rated ≥ 20 films on BOTH sides of
--      the switch (each user is their own control);
--  (c) a placebo: the same within-user change across a date with no rule
--      change (5 years later), to net out drift that happens anyway.
-- Paired t = mean(d) / (sd(d) / √n); difference-in-differences = (b) − (c).
-- Here (a): the distribution of stars, % of ratings in each era (2 years either side).
-- =====================================================================

SELECT stars,
       round(100.0 * count(*) FILTER (WHERE rated_at <  half_star_switch())
             / sum(count(*) FILTER (WHERE rated_at <  half_star_switch())) OVER (), 1) AS before_pct,
       round(100.0 * count(*) FILTER (WHERE rated_at >= half_star_switch())
             / sum(count(*) FILTER (WHERE rated_at >= half_star_switch())) OVER (), 1) AS after_pct
FROM rating
WHERE rated_at BETWEEN half_star_switch() - interval '2 years' AND half_star_switch() + interval '2 years'
GROUP BY stars
ORDER BY stars;

-- =====================================================================
-- A3. WITHIN-USER CHANGE AT THE SWITCH, AGAINST A PLACEBO DATE
-- (b) and (c) of A2: users with ≥ 20 ratings in the 2 years before AND after.
-- =====================================================================

WITH events(label, at) AS (
    VALUES ('half-star switch', half_star_switch()),
           ('placebo (+5 years)', half_star_switch() + interval '5 years')
), per_user AS (
    SELECT e.label, r.user_id,
           avg(r.stars) FILTER (WHERE r.rated_at <  e.at) AS before_mean,
           avg(r.stars) FILTER (WHERE r.rated_at >= e.at) AS after_mean,
           avg(CASE WHEN mod(r.stars, 1) <> 0 THEN 1.0 ELSE 0 END) FILTER (WHERE r.rated_at >= e.at) AS half_share_after
    FROM events e
    JOIN rating r ON r.rated_at BETWEEN e.at - interval '2 years' AND e.at + interval '2 years'
    GROUP BY e.label, r.user_id
    HAVING count(*) FILTER (WHERE r.rated_at <  e.at) >= 20
       AND count(*) FILTER (WHERE r.rated_at >= e.at) >= 20
), d AS (
    SELECT label, count(*) AS users,
           avg(after_mean - before_mean)    AS mean_change,
           stddev(after_mean - before_mean) AS sd_change,
           avg(half_share_after)            AS half_share_after
    FROM per_user GROUP BY label
)
SELECT label, users,
       round(mean_change, 4)                                  AS within_user_change,
       round((mean_change / (sd_change / sqrt(users)))::numeric, 2) AS paired_t,
       round(100 * half_share_after, 1)                       AS half_star_use_after_pct,
       round(mean_change - (SELECT mean_change FROM d WHERE label LIKE 'placebo%'), 4) AS diff_in_diff
FROM d
ORDER BY label;


-- =====================================================================
-- A4. ARE OLD FILMS BETTER, OR DO WE ONLY REMEMBER THE GOOD ONES?
-- (a) Between films: mean stars by the film's age when it was rated.
-- (b) Within films: does the SAME film's rating change as it ages?
--     Each rating is demeaned by its film's mean (a film fixed effect),
--     then regressed on age: regr_slope(stars − film mean, age).
--     If (a) rises with age but (b) is flat, old films look better only
--     because the forgotten ones were never rated: survivorship / selection.
-- Here (a).
-- =====================================================================

SELECT CASE WHEN age < 1 THEN '0 (release year)'  WHEN age < 3  THEN '1-2'
            WHEN age < 6 THEN '3-5'   WHEN age < 11 THEN '6-10'  WHEN age < 21 THEN '11-20'
            WHEN age < 41 THEN '21-40' ELSE '41+' END AS film_age_years,
       count(*)                 AS ratings,
       round(avg(stars), 3)     AS mean_stars,
       count(DISTINCT movie_id) AS films
FROM (SELECT r.movie_id, r.stars, extract(year FROM r.rated_at) - m.release_year AS age
      FROM rating r JOIN movie m USING (movie_id)
      WHERE m.release_year IS NOT NULL) x
WHERE age >= 0
GROUP BY 1
ORDER BY min(age);

-- =====================================================================
-- A5. DOES THE SAME FILM'S RATING CHANGE AS IT AGES?
-- (b) of A4: films released 1996-2012 with ≥ 1,000 ratings, rated 0-10 years after
-- release; the within-film slope uses ratings demeaned by the film's mean.
-- =====================================================================

SELECT count(DISTINCT r.movie_id)                                         AS films,
       count(*)                                                           AS ratings,
       round(regr_slope(r.stars - s.mean_stars,
                        extract(year FROM r.rated_at) - m.release_year)::numeric, 4) AS within_film_slope_per_year,
       round(regr_slope(r.stars, extract(year FROM r.rated_at) - m.release_year)::numeric, 4) AS pooled_slope_per_year
FROM rating r
JOIN movie m          USING (movie_id)
JOIN mv_movie_stats s USING (movie_id)
WHERE m.release_year BETWEEN 1996 AND 2012 AND s.n_ratings >= 1000
  AND extract(year FROM r.rated_at) - m.release_year BETWEEN 0 AND 10;


-- =====================================================================
-- A6. ARE POPULAR FILMS BETTER?
-- Mean stars by popularity decile (films with ≥ 10 ratings), and the
-- Pearson correlation of ln(ratings) with mean stars across those films.
-- =====================================================================

WITH f AS (
    SELECT movie_id, n_ratings, mean_stars, ntile(10) OVER (ORDER BY n_ratings) AS pop_decile
    FROM mv_movie_stats WHERE n_ratings >= 10
)
SELECT pop_decile, min(n_ratings) AS min_ratings, max(n_ratings) AS max_ratings,
       round(avg(mean_stars), 3) AS mean_of_film_means,
       (SELECT round(corr(ln(n_ratings), mean_stars)::numeric, 3) FROM f) AS corr_ln_pop_vs_mean
FROM f
GROUP BY pop_decile
ORDER BY pop_decile;

-- =====================================================================
-- A7. DO MOVIELENS USERS AGREE WITH IMDb?
-- Feature films with ≥ 100 MovieLens ratings and ≥ 1,000 IMDb votes: Pearson
-- correlation of the scores, Spearman (Pearson on ranks) of the orderings.
-- =====================================================================

WITH both_sites AS (
    SELECT bayes_stars, imdb_rating,
           rank() OVER (ORDER BY bayes_stars) AS r_ml,
           rank() OVER (ORDER BY imdb_rating) AS r_imdb
    FROM v_movie
    WHERE n_ratings >= 100 AND imdb_votes >= 1000 AND type_code = 'movie'
)
SELECT count(*)                                         AS films,
       round(corr(bayes_stars, imdb_rating)::numeric, 3) AS pearson,
       round(corr(r_ml, r_imdb)::numeric, 3)             AS spearman
FROM both_sites;


-- =====================================================================
-- A8. WHICH GENRES DIVIDE PEOPLE?
-- Mean, standard deviation, and the shares of "loved" (≥ 4.5) and
-- "hated" (≤ 1.5) ratings per genre. A film in several genres counts in
-- each (rating ⋈ movie_genre ⋈ genre: ~70M joined rows).
-- =====================================================================

SELECT g.genre_name, count(*) AS ratings,
       round(avg(r.stars), 3)                                        AS mean_stars,
       round(stddev(r.stars), 3)                                     AS sd_stars,
       round(100.0 * count(*) FILTER (WHERE r.stars >= 4.5) / count(*), 1) AS loved_pct,
       round(100.0 * count(*) FILTER (WHERE r.stars <= 1.5) / count(*), 1) AS hated_pct
FROM rating r
JOIN movie_genre mg USING (movie_id)
JOIN genre g        USING (genre_id)
GROUP BY g.genre_name
ORDER BY mean_stars DESC;


-- =====================================================================
-- A9. DO USERS GET HARSHER WITH EXPERIENCE?
-- Each user's ratings are numbered in time order; stars are demeaned by
-- the user's own mean (a user fixed effect), so the curve shows how ONE
-- person's ratings drift, not who stays on the site.
-- =====================================================================

WITH seq AS (
    SELECT r.stars - u.mean_stars AS dev,
           row_number() OVER (PARTITION BY r.user_id ORDER BY r.rated_at, r.movie_id) AS k
    FROM rating r JOIN mv_user_stats u USING (user_id)
    WHERE u.n_ratings >= 500
)
SELECT CASE WHEN k <= 20 THEN '001-020' WHEN k <= 50 THEN '021-050' WHEN k <= 100 THEN '051-100'
            WHEN k <= 200 THEN '101-200' WHEN k <= 500 THEN '201-500' ELSE '501+' END AS nth_rating,
       count(*)              AS ratings,
       round(avg(dev), 4)    AS vs_own_mean
FROM seq
GROUP BY 1 ORDER BY 1;


-- =====================================================================
-- Recommender tables (rebuilt by build_recommender())
-- Temporal holdout: train = ratings before 2021-01-01, test = after.
-- A "like" is ≥ 4 stars. Catalogue = the 2,000 most-liked films in train.
-- =====================================================================
CREATE TABLE IF NOT EXISTS rec_item (            -- the catalogue
    movie_id     integer PRIMARY KEY REFERENCES movie,
    train_likes  integer NOT NULL CHECK (train_likes > 0)
);
CREATE TABLE IF NOT EXISTS rec_neighbor (        -- item-to-item similarity, top 50 per film
    movie_id     integer NOT NULL REFERENCES rec_item ON DELETE CASCADE,
    neighbor_id  integer NOT NULL REFERENCES rec_item ON DELETE CASCADE,
    co_likes     integer NOT NULL CHECK (co_likes > 0),
    cosine       numeric(6, 5) NOT NULL CHECK (cosine > 0 AND cosine <= 1),
    PRIMARY KEY (movie_id, neighbor_id),
    CHECK (movie_id <> neighbor_id)
);
CREATE TABLE IF NOT EXISTS rec_test_user (
    user_id  integer PRIMARY KEY REFERENCES ml_user
);
CREATE TABLE IF NOT EXISTS rec_list (            -- top-10 lists per method and user
    method    varchar(10) NOT NULL CHECK (method IN ('POPULAR', 'TOP_RATED', 'ITEM_KNN')),
    user_id   integer  NOT NULL REFERENCES rec_test_user ON DELETE CASCADE,
    rank      smallint NOT NULL CHECK (rank BETWEEN 1 AND 10),
    movie_id  integer  NOT NULL REFERENCES rec_item,
    PRIMARY KEY (method, user_id, rank),
    UNIQUE (method, user_id, movie_id)
);

CREATE OR REPLACE PROCEDURE build_recommender(p_cut timestamptz DEFAULT '2021-01-01')
LANGUAGE plpgsql AS $$
BEGIN
    DELETE FROM rec_list; DELETE FROM rec_test_user; DELETE FROM rec_neighbor; DELETE FROM rec_item;

    INSERT INTO rec_item
    SELECT movie_id, count(*) FROM rating
    WHERE rated_at < p_cut AND stars >= 4
    GROUP BY movie_id ORDER BY count(*) DESC, movie_id LIMIT 2000;

    -- Test users: ≥ 20 ratings in train, ≥ 5 catalogue films liked in test;
    -- a fixed 1-in-10 slice of user ids keeps the evaluation reproducible
    INSERT INTO rec_test_user
    SELECT r.user_id FROM rating r
    WHERE r.user_id % 10 = 3
    GROUP BY r.user_id
    HAVING count(*) FILTER (WHERE r.rated_at < p_cut) >= 20
       AND count(*) FILTER (WHERE r.rated_at >= p_cut AND r.stars >= 4
                              AND r.movie_id IN (SELECT movie_id FROM rec_item)) >= 5;

    -- Co-likes from a 1-in-4 sample of users, each user's 100 most recent
    -- train likes (bounds the self-join: a user with k likes adds k² pairs)
    CREATE TEMP TABLE tl ON COMMIT DROP AS
    SELECT user_id, movie_id FROM (
        SELECT r.user_id, r.movie_id,
               row_number() OVER (PARTITION BY r.user_id ORDER BY r.rated_at DESC, r.movie_id) AS k
        FROM rating r JOIN rec_item USING (movie_id)
        WHERE r.rated_at < p_cut AND r.stars >= 4 AND r.user_id % 4 = 0) x
    WHERE k <= 100;
    ANALYZE tl;

    INSERT INTO rec_neighbor
    WITH n AS (SELECT movie_id, count(*) AS n FROM tl GROUP BY movie_id),
    co AS (
        SELECT a.movie_id AS i, b.movie_id AS j, count(*) AS c
        FROM tl a JOIN tl b ON b.user_id = a.user_id AND b.movie_id <> a.movie_id
        GROUP BY a.movie_id, b.movie_id
    ), ranked AS (
        SELECT co.i, co.j, co.c, co.c / sqrt(ni.n::numeric * nj.n) AS cosine,
               row_number() OVER (PARTITION BY co.i ORDER BY co.c / sqrt(ni.n::numeric * nj.n) DESC, co.j) AS k
        FROM co JOIN n ni ON ni.movie_id = co.i JOIN n nj ON nj.movie_id = co.j
        WHERE co.c >= 5
    )
    SELECT i, j, c, round(cosine, 5) FROM ranked WHERE k <= 50;

    -- Each test user's train history: what they have seen, what they liked
    CREATE TEMP TABLE hist ON COMMIT DROP AS
    SELECT r.user_id, r.movie_id, r.stars, r.rated_at
    FROM rating r JOIN rec_test_user USING (user_id)
    WHERE r.rated_at < p_cut;
    CREATE INDEX ON hist (user_id, movie_id);
    ANALYZE hist;

    -- POPULAR: most-liked catalogue films the user has not rated
    INSERT INTO rec_list
    SELECT 'POPULAR', user_id, k, movie_id FROM (
        SELECT u.user_id, i.movie_id,
               row_number() OVER (PARTITION BY u.user_id ORDER BY i.train_likes DESC, i.movie_id) AS k
        FROM rec_test_user u CROSS JOIN (SELECT * FROM rec_item ORDER BY train_likes DESC LIMIT 300) i
        WHERE NOT EXISTS (SELECT 1 FROM hist h WHERE h.user_id = u.user_id AND h.movie_id = i.movie_id)) x
    WHERE k <= 10;

    -- TOP_RATED: highest Bayesian average in train (prior of 50 ratings)
    INSERT INTO rec_list
    WITH q AS (
        SELECT r.movie_id,
               (50 * 3.5 + sum(r.stars)) / (50 + count(*)) AS bayes
        FROM rating r JOIN rec_item USING (movie_id)
        WHERE r.rated_at < p_cut GROUP BY r.movie_id ORDER BY bayes DESC LIMIT 300
    )
    SELECT 'TOP_RATED', user_id, k, movie_id FROM (
        SELECT u.user_id, q.movie_id,
               row_number() OVER (PARTITION BY u.user_id ORDER BY q.bayes DESC, q.movie_id) AS k
        FROM rec_test_user u CROSS JOIN q
        WHERE NOT EXISTS (SELECT 1 FROM hist h WHERE h.user_id = u.user_id AND h.movie_id = q.movie_id)) x
    WHERE k <= 10;

    -- ITEM_KNN: score(j) = Σ cosine(i, j) over the user's 50 most recent likes i
    INSERT INTO rec_list
    WITH seeds AS (
        SELECT user_id, movie_id FROM (
            SELECT h.user_id, h.movie_id,
                   row_number() OVER (PARTITION BY h.user_id ORDER BY h.rated_at DESC, h.movie_id) AS k
            FROM hist h JOIN rec_item USING (movie_id) WHERE h.stars >= 4) x
        WHERE k <= 50
    ), scored AS (
        SELECT s.user_id, nb.neighbor_id AS movie_id, sum(nb.cosine) AS score
        FROM seeds s JOIN rec_neighbor nb ON nb.movie_id = s.movie_id
        WHERE NOT EXISTS (SELECT 1 FROM hist h WHERE h.user_id = s.user_id AND h.movie_id = nb.neighbor_id)
        GROUP BY s.user_id, nb.neighbor_id
    )
    SELECT 'ITEM_KNN', user_id, k, movie_id FROM (
        SELECT user_id, movie_id, row_number() OVER (PARTITION BY user_id ORDER BY score DESC, movie_id) AS k
        FROM scored) x
    WHERE k <= 10;
END $$;

CALL build_recommender();
ANALYZE rec_item; ANALYZE rec_neighbor; ANALYZE rec_list;


-- =====================================================================
-- R1. CAN A RECOMMENDER WRITTEN IN SQL BEAT "SHOW EVERYONE THE HITS"?
-- For each method, over the test users: hit rate@10 (share of users with
-- at least one liked film in their 10), precision@10, recall@10 (share of
-- the user's test likes that were recommended), and catalogue coverage
-- (how many distinct films the method ever recommends).
-- =====================================================================

WITH test_likes AS (
    SELECT r.user_id, r.movie_id
    FROM rating r JOIN rec_test_user USING (user_id) JOIN rec_item USING (movie_id)
    WHERE r.rated_at >= '2021-01-01' AND r.stars >= 4
), per_user AS (
    SELECT l.method, l.user_id,
           count(t.movie_id)                                              AS hits,
           (SELECT count(*) FROM test_likes x WHERE x.user_id = l.user_id) AS likes
    FROM rec_list l
    LEFT JOIN test_likes t ON t.user_id = l.user_id AND t.movie_id = l.movie_id
    GROUP BY l.method, l.user_id
)
SELECT p.method, count(*) AS users,
       round(100.0 * avg(CASE WHEN hits > 0 THEN 1 ELSE 0 END), 1) AS hit_rate_pct,
       round(100.0 * avg(hits / 10.0), 2)                          AS precision_pct,
       round(100.0 * avg(hits::numeric / likes), 2)                AS recall_pct,
       (SELECT count(DISTINCT movie_id) FROM rec_list l WHERE l.method = p.method) AS films_ever_recommended
FROM per_user p
GROUP BY p.method
ORDER BY hit_rate_pct DESC;


-- =====================================================================
-- R2. WHAT DOES THE SIMILARITY GRAPH SAY? Nearest neighbours of three
-- well-known films (cosine on co-likes; nothing about genre or plot was
-- given to the algorithm).
-- =====================================================================

SELECT m.title AS film, nb_rank, n.title AS neighbour, cosine
FROM (SELECT nb.movie_id, nb.neighbor_id, nb.cosine,
             row_number() OVER (PARTITION BY nb.movie_id ORDER BY nb.cosine DESC) AS nb_rank
      FROM rec_neighbor nb
      WHERE nb.movie_id IN (SELECT movie_id FROM movie
                            WHERE (title, release_year) IN (('Toy Story', 1995), ('Matrix, The', 1999),
                                                            ('Pride & Prejudice', 2005)))) x
JOIN movie m ON m.movie_id = x.movie_id
JOIN movie n ON n.movie_id = x.neighbor_id
WHERE nb_rank <= 5
ORDER BY m.title, nb_rank;


-- =====================================================================
-- v_user_features: the k-means input, one row per user (all 200,948)
--   ln_ratings       ln(number of ratings)              activity
--   mean_stars       average stars given                generosity
--   sd_stars         spread of the user's stars         how much of the scale they use
--   mainstream       avg ln(ratings of the films rated) taste for popular films
--   classic_share    share of ratings on films ≥ 20 years old when rated
--   conformity       corr(user's stars, film's mean)    agreement with the crowd
--   half_share       share of half-star ratings         precision of rating
-- =====================================================================
DROP VIEW IF EXISTS v_segment_profile;
DROP VIEW IF EXISTS v_user_features;
CREATE VIEW v_user_features AS
SELECT r.user_id,
       ln(count(*))                                                        AS ln_ratings,
       avg(r.stars)                                                        AS mean_stars,
       coalesce(stddev(r.stars), 0)                                        AS sd_stars,
       avg(ln(s.n_ratings))                                                AS mainstream,
       avg(CASE WHEN extract(year FROM r.rated_at) - m.release_year >= 20 THEN 1.0 ELSE 0 END) AS classic_share,
       coalesce(corr(r.stars, s.mean_stars), 0)                            AS conformity,
       avg(CASE WHEN mod(r.stars, 1) <> 0 THEN 1.0 ELSE 0 END)             AS half_share
FROM rating r
JOIN mv_movie_stats s USING (movie_id)
JOIN movie m          USING (movie_id)
GROUP BY r.user_id;


-- =====================================================================
-- Segment tables (BCNF): the notebook writes k-means results here
-- =====================================================================
CREATE TABLE IF NOT EXISTS segment (
    segment_id    smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    segment_name  varchar(40) NOT NULL UNIQUE,
    description   text        NOT NULL
);

CREATE TABLE IF NOT EXISTS user_segment (
    user_id     integer  PRIMARY KEY REFERENCES ml_user ON DELETE CASCADE,
    segment_id  smallint NOT NULL REFERENCES segment ON DELETE CASCADE,
    distance    numeric(6, 3) NOT NULL CHECK (distance >= 0)   -- to the centroid, in SD units
);

CREATE VIEW v_segment_profile AS
SELECT s.segment_name, count(*) AS users,
       round(avg(u.n_ratings)) AS avg_ratings, round(avg(u.mean_stars), 2) AS avg_stars
FROM segment s
JOIN user_segment us USING (segment_id)
JOIN mv_user_stats u ON u.user_id = us.user_id
GROUP BY s.segment_id, s.segment_name;

GRANT SELECT ON ALL TABLES IN SCHEMA movielens TO movielens_readonly;


-- =====================================================================
-- S1. WHAT DOES EACH SEGMENT WATCH?
-- Each segment's share of ratings per genre, divided by the share across
-- all users (lift > 1 = the segment over-watches that genre).
-- =====================================================================

WITH seg_genre AS (
    SELECT sg.segment_name, g.genre_name, count(*) AS n
    FROM user_segment us
    JOIN segment sg     USING (segment_id)
    JOIN rating r       ON r.user_id = us.user_id
    JOIN movie_genre mg ON mg.movie_id = r.movie_id
    JOIN genre g        ON g.genre_id = mg.genre_id
    GROUP BY 1, 2
), shares AS (
    SELECT segment_name, genre_name,
           n::numeric / sum(n) OVER (PARTITION BY segment_name)                   AS seg_share,
           sum(n) OVER (PARTITION BY genre_name)::numeric / sum(n) OVER ()         AS all_share
    FROM seg_genre
)
SELECT segment_name, genre_name, round(100 * seg_share, 1) AS share_pct,
       round(seg_share / all_share, 2) AS lift
FROM shares
WHERE genre_name <> 'IMAX'
ORDER BY segment_name, lift DESC;


-- =====================================================================
-- S2. WHICH SEGMENT IS THE RECOMMENDER GOOD FOR?
-- Item-kNN hit rate@10 by segment, against the popularity baseline:
-- a recommender's value is not the same for every kind of user.
-- =====================================================================

WITH test_likes AS (
    SELECT r.user_id, r.movie_id
    FROM rating r JOIN rec_test_user USING (user_id) JOIN rec_item USING (movie_id)
    WHERE r.rated_at >= '2021-01-01' AND r.stars >= 4
), per_user AS (
    SELECT l.method, l.user_id, count(t.movie_id) AS hits
    FROM rec_list l
    LEFT JOIN test_likes t ON t.user_id = l.user_id AND t.movie_id = l.movie_id
    GROUP BY l.method, l.user_id
)
SELECT sg.segment_name, count(*) FILTER (WHERE p.method = 'ITEM_KNN') AS test_users,
       round(100.0 * avg(CASE WHEN hits > 0 THEN 1 ELSE 0 END) FILTER (WHERE p.method = 'ITEM_KNN'), 1) AS knn_hit_rate_pct,
       round(100.0 * avg(CASE WHEN hits > 0 THEN 1 ELSE 0 END) FILTER (WHERE p.method = 'POPULAR'), 1)  AS popular_hit_rate_pct
FROM per_user p
JOIN user_segment us USING (user_id)
JOIN segment sg      USING (segment_id)
GROUP BY sg.segment_id, sg.segment_name
ORDER BY knn_hit_rate_pct DESC;
