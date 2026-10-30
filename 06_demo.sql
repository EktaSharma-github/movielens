-- =====================================================================
--  MovieLens 32M  |  Live demo (about 4 minutes)
--
--  Every change runs inside BEGIN ... ROLLBACK, so the demo can be
--  repeated any number of times and never alters the loaded data.
--  Run:  psql -U postgres -h localhost -d movielens -f 06_demo.sql
--  Errors are EXPECTED in steps 2-5: they are the rules firing.
-- =====================================================================

SET search_path TO movielens, public;
SET timezone = 'UTC';   -- years and dates of ratings are UTC (the dataset's clock)
\set ON_ERROR_STOP 0
\pset footer off

\echo
\echo '=== 1. From a CSV line to relations ==='
\echo '    movies.csv:  1,Toy Story (1995),Adventure|Animation|Children|Comedy|Fantasy'
\echo '    Title and year were one string, genres a list (not 1NF). Now:'
SELECT m.movie_id, m.title, m.release_year, m.year_source, 'tt' || lpad(m.imdb_id::text, 7, '0') AS imdb,
       string_agg(g.genre_name, ', ' ORDER BY g.genre_name) AS genres
FROM movie m JOIN movie_genre mg USING (movie_id) JOIN genre g USING (genre_id)
WHERE m.movie_id = 1
GROUP BY m.movie_id;
\echo '    ... and a title with no year, rescued from IMDb (BR-6):'
SELECT movie_id, title, release_year, year_source FROM movie
WHERE year_source = 'IMDB' ORDER BY movie_id LIMIT 3;

\echo
\echo '=== 2. BR-1: stars are 0.5 to 5 in half steps (CHECK) ==='
BEGIN;
UPDATE rating SET stars = 4.25 WHERE user_id = 1 AND movie_id = 17;
ROLLBACK;

\echo
\echo '=== 3. BR-3: no half stars before February 2003 (trigger + rating_scale) ==='
SELECT scale_code, valid_from, valid_to, step, min_stars FROM rating_scale ORDER BY valid_from;
\echo '    User 1 rates a film 3.5 stars in 1999:'
BEGIN;
INSERT INTO rating (user_id, movie_id, stars, rated_at)
SELECT 1, min(movie_id), 3.5, '1999-12-01'
FROM movie WHERE movie_id NOT IN (SELECT movie_id FROM rating WHERE user_id = 1);
ROLLBACK;
\echo '    The same rating in 2010 is fine (rolled back anyway):'
BEGIN;
INSERT INTO rating (user_id, movie_id, stars, rated_at)
SELECT 1, min(movie_id), 3.5, '2010-12-01'
FROM movie WHERE movie_id NOT IN (SELECT movie_id FROM rating WHERE user_id = 1);
ROLLBACK;
\echo '    And the scales themselves cannot overlap (GiST exclusion): stretch WHOLE to 2005'
BEGIN;
UPDATE rating_scale SET valid_to = '2005-01-01' WHERE scale_code = 'WHOLE';
ROLLBACK;

\echo
\echo '=== 4. BR-4: every user has >= 20 ratings (an ASSERTION, emulated by triggers) ==='
\echo '    (a) a new user arrives with a single rating:'
BEGIN;
INSERT INTO ml_user VALUES (999999);
INSERT INTO rating VALUES (999999, 1, 4.0, '2023-01-01');
ROLLBACK;
\echo '    (b) delete one rating of a user who has exactly 20:'
BEGIN;
DELETE FROM rating
WHERE (user_id, movie_id) = (SELECT r.user_id, min(r.movie_id) FROM rating r
                              WHERE r.user_id = (SELECT user_id FROM mv_user_stats WHERE n_ratings = 20 ORDER BY user_id LIMIT 1)
                              GROUP BY r.user_id);
ROLLBACK;
\echo '    (c) but 20 ratings inserted in ONE statement pass: the check runs once, at the end'
BEGIN;
INSERT INTO ml_user VALUES (999999);
INSERT INTO rating SELECT 999999, movie_id, 4.0, '2023-01-01' FROM movie ORDER BY movie_id LIMIT 20;
SELECT count(*) AS new_user_ratings FROM rating WHERE user_id = 999999;
ROLLBACK;

\echo
\echo '=== 5. BR-5: a rating cannot move to another film (row trigger) ==='
BEGIN;
UPDATE rating SET movie_id = 2 WHERE user_id = 1 AND movie_id = 17;
ROLLBACK;

\echo
\echo '=== 6. A materialized view is a cache: stale until refreshed ==='
\echo '    (mv_movie_stats covers all 32M ratings; for the demo, the same definition for one film)'
BEGIN;
CREATE MATERIALIZED VIEW demo_stats AS
SELECT movie_id, count(*) AS n_ratings, round(avg(stars), 3) AS mean_stars
FROM rating WHERE movie_id = 1 GROUP BY movie_id;
\echo '    20 new users rate Toy Story 0.5 stars ...'
INSERT INTO ml_user SELECT 999000 + g FROM generate_series(1, 20) g;
INSERT INTO rating
SELECT 999000 + g, m.movie_id, CASE WHEN m.movie_id = 1 THEN 0.5 ELSE 3.0 END, '2023-06-01'
FROM generate_series(1, 20) g CROSS JOIN (SELECT movie_id FROM movie ORDER BY movie_id LIMIT 20) m;
SELECT 'before REFRESH' AS state, * FROM demo_stats;
REFRESH MATERIALIZED VIEW demo_stats;
SELECT 'after REFRESH' AS state, * FROM demo_stats;
ROLLBACK;
\echo '    Rolled back: the users, the ratings and the refresh are all undone.'

\echo
\echo '=== 7. Indexing: "all ratings of one film" on 32M rows ==='
\echo '    TIMING OFF: per-row timing overhead on Windows would otherwise distort the comparison.'
\echo '    The PK (user_id, movie_id) cannot help (movie_id is not its first column); ix_rating_movie can.'
BEGIN;
EXPLAIN (ANALYZE, TIMING OFF, COSTS OFF, SUMMARY ON)
SELECT count(*), avg(stars) FROM rating WHERE movie_id = 3000;
DROP INDEX ix_rating_movie;
\echo '    ix_rating_movie dropped (inside the transaction). Same query:'
EXPLAIN (ANALYZE, TIMING OFF, COSTS OFF, SUMMARY ON)
SELECT count(*), avg(stars) FROM rating WHERE movie_id = 3000;
ROLLBACK;
\echo '    Rolled back: the index is restored.'

\echo
\echo '=== 8. The data-quality log: real but suspicious rows are kept, with the reason ==='
SELECT i.issue_code, t.description, count(*) AS cases
FROM data_issue i JOIN issue_type t USING (issue_code)
GROUP BY i.issue_code, t.description ORDER BY cases DESC;

\echo
\echo '=== 9. Least privilege: the analytics role can read, not write ==='
SET ROLE movielens_readonly;
SELECT count(*) AS ratings_visible FROM rating;
DELETE FROM rating WHERE user_id = 1;
RESET ROLE;
