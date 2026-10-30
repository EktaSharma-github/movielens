-- =====================================================================
--  MovieLens 32M  |  Five advanced queries
--
--  Each query is labelled with:
--    QUESTION            what a film researcher or a recommender team wants to know
--    FDS CONCEPTS        what the query demonstrates
--    RELATIONAL ALGEBRA  where it adds insight
--
--  Q1  Window functions: ranking inside partitions            (best film per genre, honestly ranked)
--  Q2  Relational DIVISION with double NOT EXISTS             (the Nolan completists)
--  Q3  Recursive CTE over a graph: breadth-first search         (degrees of co-direction)
--  Q4  LATERAL joins: a correlated top-N per row               (what people call a film)
--  Q5  Set operations: INTERSECT and EXCEPT                    (IMDb vs MovieLens disagreements)
-- =====================================================================

SET search_path TO movielens, public;
SET timezone = 'UTC';   -- years and dates of ratings are UTC (the dataset's clock)


-- =====================================================================
-- Q1. WHAT IS THE BEST FILM IN EACH GENRE?
-- QUESTION
--   Rank films within every genre by their Bayesian (shrunk) average, and
--   show how far each would move if ranked by the raw mean instead.
-- FDS CONCEPTS
--   Window functions: RANK() OVER (PARTITION BY genre ORDER BY ...), two
--   different orderings over the same partition; a view (v_movie) hiding a
--   materialized aggregate; filtering on a window result needs a subquery
--   (window functions run after WHERE).
-- =====================================================================

WITH ranked AS (
    SELECT g.genre_name, v.title, v.release_year, v.n_ratings,
           v.mean_stars, v.bayes_stars,
           rank() OVER (PARTITION BY g.genre_name ORDER BY v.bayes_stars DESC) AS bayes_rank,
           rank() OVER (PARTITION BY g.genre_name ORDER BY v.mean_stars  DESC) AS raw_rank
    FROM v_movie v
    JOIN v_movie_genre g USING (movie_id)
    WHERE v.n_ratings >= 50
)
SELECT genre_name, bayes_rank AS rank, title, release_year, n_ratings,
       mean_stars, bayes_stars, raw_rank AS rank_if_raw_mean
FROM ranked
WHERE bayes_rank <= 3 AND genre_name <> 'IMAX'
ORDER BY genre_name, bayes_rank;


-- =====================================================================
-- Q2. WHO HAS SEEN EVERY CHRISTOPHER NOLAN FILM?
-- QUESTION
--   Users who rated ALL of Nolan's feature films in the catalogue, and how
--   their average Nolan rating compares with everyone else's.
-- FDS CONCEPTS
--   Relational division (÷) written as a double NOT EXISTS:
--   "there is no Nolan film that this user has not rated".
--   Joins across both sources: person ⋈ title_director ⋈ movie (IMDb → ML).
-- RELATIONAL ALGEBRA
--   π_user,movie(rating) ÷ π_movie(σ_name='Christopher Nolan'(person) ⋈ title_director ⋈ movie)
-- =====================================================================

WITH nolan AS (                      -- the divisor: his feature films that MovieLens lists
    SELECT m.movie_id
    FROM person p
    JOIN title_director td USING (person_id)
    JOIN imdb_title it     USING (imdb_id)
    JOIN movie m           USING (imdb_id)
    WHERE p.full_name = 'Christopher Nolan' AND p.birth_year = 1970
      AND it.type_code = 'movie'
), completists AS (
    SELECT u.user_id
    FROM ml_user u
    WHERE NOT EXISTS (SELECT 1 FROM nolan n
                      WHERE NOT EXISTS (SELECT 1 FROM rating r
                                        WHERE r.user_id = u.user_id AND r.movie_id = n.movie_id))
)
SELECT (SELECT count(*) FROM nolan)                                             AS nolan_films,
       (SELECT count(*) FROM completists)                                       AS completists,
       (SELECT count(DISTINCT user_id) FROM rating JOIN nolan USING (movie_id))  AS rated_any_nolan,
       round((SELECT avg(stars) FROM rating JOIN nolan USING (movie_id)
               WHERE user_id IN (SELECT user_id FROM completists)), 3)          AS completist_avg,
       round((SELECT avg(stars) FROM rating JOIN nolan USING (movie_id)
               WHERE user_id NOT IN (SELECT user_id FROM completists)), 3)      AS others_avg;


-- =====================================================================
-- Q3. HOW CONNECTED ARE DIRECTORS?
-- QUESTION
--   Starting from Ethan Coen, who can be reached by co-directing a film
--   (A co-directed with B, B with C, ...)? How many directors at each
--   distance, with examples.
-- FDS CONCEPTS
--   Recursive CTE: breadth-first search over a graph stored as a relation
--   (edges = pairs of directors sharing a title, a self-join of
--   title_director). UNION, not UNION ALL: with set semantics each level
--   keeps one row per (director, depth). Our first version carried the
--   whole path in each row (UNION ALL + CYCLE): anthology films with 10-20
--   co-directors made the number of PATHS explode, and it ran for over 10
--   minutes. Deduplicating states instead of paths bounds the work by
--   directors × depth. MIN(depth) per director = shortest distance.
-- =====================================================================

WITH RECURSIVE edge AS (
    SELECT DISTINCT a.person_id AS src, b.person_id AS dst
    FROM title_director a
    JOIN title_director b ON b.imdb_id = a.imdb_id AND b.person_id <> a.person_id
    JOIN movie m          ON m.imdb_id = a.imdb_id          -- titles in the MovieLens catalogue
), walk (person_id, depth) AS (
    SELECT person_id, 0 FROM person WHERE full_name = 'Ethan Coen'
    UNION
    SELECT e.dst, w.depth + 1
    FROM walk w JOIN edge e ON e.src = w.person_id
    WHERE w.depth < 6
), shortest AS (
    SELECT person_id, min(depth) AS depth FROM walk GROUP BY person_id
), ranked AS (           -- the best-known directors at each distance (most credits)
    SELECT s.depth, p.full_name,
           row_number() OVER (PARTITION BY s.depth
                              ORDER BY (SELECT count(*) FROM title_director t WHERE t.person_id = s.person_id) DESC,
                                       p.full_name) AS rk
    FROM shortest s JOIN person p USING (person_id)
)
SELECT depth, count(*) AS directors,
       string_agg(full_name, ', ' ORDER BY rk) FILTER (WHERE rk <= 4) AS best_known
FROM ranked
GROUP BY depth
ORDER BY depth;


-- =====================================================================
-- Q4. WHAT DO PEOPLE CALL A FILM?
-- QUESTION
--   For the 10 most-tagged films, the 3 most common tags (case-folded,
--   so "Sci-Fi" and "sci-fi" count together) and how many users used each.
-- FDS CONCEPTS
--   LATERAL: a subquery that runs once per outer row and may use its
--   columns (a correlated top-N, impossible with a plain join); the derived
--   key tag_key (a generated column) as the grouping attribute.
-- =====================================================================

WITH top_tagged AS (
    SELECT movie_id, count(*) AS applications, count(DISTINCT user_id) AS taggers
    FROM tag_application
    GROUP BY movie_id
    ORDER BY applications DESC
    LIMIT 10
)
SELECT m.title, m.release_year, tt.applications, tt.taggers, top3.tag_key, top3.users
FROM top_tagged tt
JOIN movie m USING (movie_id)
CROSS JOIN LATERAL (
    SELECT t.tag_key, count(DISTINCT ta.user_id) AS users
    FROM tag_application ta JOIN tag t USING (tag_id)
    WHERE ta.movie_id = tt.movie_id
    GROUP BY t.tag_key
    ORDER BY users DESC, t.tag_key
    LIMIT 3
) top3
ORDER BY tt.applications DESC, top3.users DESC;


-- =====================================================================
-- Q5. WHERE DO MOVIELENS USERS AND IMDb DISAGREE?
-- QUESTION
--   Among films well known on both sites (≥ 1,000 MovieLens ratings and
--   ≥ 50,000 IMDb votes), which are in IMDb's top fifth but not MovieLens'
--   top fifth, and vice versa? How big is the overlap?
-- FDS CONCEPTS
--   INTERSECT and EXCEPT: set semantics (duplicates removed), union-
--   compatible inputs; PERCENT_RANK puts the 10-point and 5-star scales
--   on one footing.
-- RELATIONAL ALGEBRA
--   IMDb_top ∩ ML_top,  IMDb_top − ML_top,  ML_top − IMDb_top
-- =====================================================================

CREATE TEMP VIEW both_known AS
SELECT movie_id, title, release_year, bayes_stars, imdb_rating,
       percent_rank() OVER (ORDER BY bayes_stars) AS ml_pct,
       percent_rank() OVER (ORDER BY imdb_rating) AS imdb_pct
FROM v_movie
WHERE n_ratings >= 1000 AND imdb_votes >= 50000;

SELECT 'loved by both' AS set_name, count(*) AS films FROM (
    SELECT movie_id FROM both_known WHERE imdb_pct >= 0.8
    INTERSECT
    SELECT movie_id FROM both_known WHERE ml_pct >= 0.8) s
UNION ALL
SELECT 'IMDb top fifth only', count(*) FROM (
    SELECT movie_id FROM both_known WHERE imdb_pct >= 0.8
    EXCEPT
    SELECT movie_id FROM both_known WHERE ml_pct >= 0.8) s
UNION ALL
SELECT 'MovieLens top fifth only', count(*) FROM (
    SELECT movie_id FROM both_known WHERE ml_pct >= 0.8
    EXCEPT
    SELECT movie_id FROM both_known WHERE imdb_pct >= 0.8) s;

-- The sharpest disagreements in each direction (rank gap in percentiles)
(SELECT 'IMDb likes more' AS side, title, release_year, imdb_rating, bayes_stars,
        round((imdb_pct - ml_pct)::numeric, 2) AS pct_gap
 FROM both_known ORDER BY imdb_pct - ml_pct DESC LIMIT 5)
UNION ALL
(SELECT 'MovieLens likes more', title, release_year, imdb_rating, bayes_stars,
        round((ml_pct - imdb_pct)::numeric, 2)
 FROM both_known ORDER BY ml_pct - imdb_pct DESC LIMIT 5);
