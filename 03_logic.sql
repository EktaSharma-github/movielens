-- =====================================================================
-- MovieLens 32M — 03_logic.sql : triggers for the cross-row rules, derived
-- statistics (never stored as base data: BR-11), the research refresh
-- procedure, and the read-only role.
-- Run after 02_ddl.sql and BEFORE loading, so every real row is checked.
-- =====================================================================
SET search_path = movielens;

-- ---------------------------------------------------------------------
-- BR-3: a rating must use the star scale in force when it was made: no
-- half stars (and no 0.5) before MovieLens introduced them in 2003.
-- Statement-level trigger with a transition table: the 32-million-row
-- insert is checked with ONE set-based join instead of 32 million lookups.
-- ---------------------------------------------------------------------
CREATE FUNCTION trg_rating_scale() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE bad record;
BEGIN
    SELECT n.user_id, n.movie_id, n.stars, n.rated_at, s.scale_code INTO bad
      FROM new_rows n
      JOIN rating_scale s ON n.rated_at >= s.valid_from AND n.rated_at < s.valid_to
     WHERE n.stars < s.min_stars OR mod(n.stars, s.step) <> 0
     LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'BR-3: % stars by user % on movie % at % is not on the % scale in force then',
            bad.stars, bad.user_id, bad.movie_id, bad.rated_at, bad.scale_code;
    END IF;
    RETURN NULL;
END $$;

CREATE TRIGGER rating_scale_ins
    AFTER INSERT ON rating REFERENCING NEW TABLE AS new_rows
    FOR EACH STATEMENT EXECUTE FUNCTION trg_rating_scale();
CREATE TRIGGER rating_scale_upd
    AFTER UPDATE ON rating REFERENCING NEW TABLE AS new_rows
    FOR EACH STATEMENT EXECUTE FUNCTION trg_rating_scale();

-- ---------------------------------------------------------------------
-- BR-4: every user in the dataset has rated at least 20 movies (GroupLens'
-- sampling rule). This is a constraint over MANY rows: standard SQL would
-- say CREATE ASSERTION, which no major DBMS implements, so it is emulated
-- with statement-level triggers that re-check only the users a statement
-- touched.
-- ---------------------------------------------------------------------
CREATE FUNCTION trg_user_min_ratings() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE bad record;
BEGIN
    WITH touched AS (SELECT DISTINCT user_id FROM changed_rows)
    SELECT t.user_id, count(r.user_id) AS n INTO bad
      FROM touched t LEFT JOIN rating r ON r.user_id = t.user_id
     GROUP BY t.user_id
    HAVING count(r.user_id) < 20
     LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'BR-4: user % would have % ratings; every user must have at least 20',
            bad.user_id, bad.n;
    END IF;
    RETURN NULL;
END $$;

CREATE TRIGGER user_min_ratings_ins
    AFTER INSERT ON rating REFERENCING NEW TABLE AS changed_rows
    FOR EACH STATEMENT EXECUTE FUNCTION trg_user_min_ratings();
CREATE TRIGGER user_min_ratings_del
    AFTER DELETE ON rating REFERENCING OLD TABLE AS changed_rows
    FOR EACH STATEMENT EXECUTE FUNCTION trg_user_min_ratings();

-- ---------------------------------------------------------------------
-- BR-5: ratings and tags are history: the user and the movie may change
-- the stars (re-rating), but a rating never moves to another user or movie
-- ---------------------------------------------------------------------
CREATE FUNCTION trg_rating_identity() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.user_id <> OLD.user_id OR NEW.movie_id <> OLD.movie_id THEN
        RAISE EXCEPTION 'BR-5: a rating cannot be moved to another user or movie (user %, movie %)',
            OLD.user_id, OLD.movie_id;
    END IF;
    IF NEW.rated_at < OLD.rated_at THEN
        RAISE EXCEPTION 'BR-5: a re-rating cannot be older than the rating it replaces';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER rating_identity
    BEFORE UPDATE ON rating
    FOR EACH ROW EXECUTE FUNCTION trg_rating_identity();

-- ---------------------------------------------------------------------
-- Derived statistics (BR-11: computed from ratings, never typed in).
-- Materialized because every analysis reads them; refresh_research()
-- rebuilds them after a load. 06_demo.sql shows one going stale.
-- ---------------------------------------------------------------------
CREATE MATERIALIZED VIEW mv_movie_stats AS
SELECT movie_id,
       count(*)                                  AS n_ratings,
       round(avg(stars), 4)                      AS mean_stars,
       round(stddev_samp(stars), 4)              AS sd_stars,
       count(*) FILTER (WHERE stars >= 4)        AS n_likes,
       min(rated_at)                             AS first_rated,
       max(rated_at)                             AS last_rated
FROM rating
GROUP BY movie_id
WITH NO DATA;
CREATE UNIQUE INDEX ux_mv_movie_stats ON mv_movie_stats (movie_id);

CREATE MATERIALIZED VIEW mv_user_stats AS
SELECT user_id,
       count(*)                                          AS n_ratings,
       round(avg(stars), 4)                              AS mean_stars,
       round(stddev_samp(stars), 4)                      AS sd_stars,
       min(rated_at)                                     AS first_rated,
       max(rated_at)                                     AS last_rated,
       count(*) FILTER (WHERE mod(stars, 1) <> 0)        AS n_half_stars
FROM rating
GROUP BY user_id
WITH NO DATA;
CREATE UNIQUE INDEX ux_mv_user_stats ON mv_user_stats (user_id);

-- Bayesian (shrunk) average: a movie with few ratings is pulled towards the
-- global mean. prior_n = how many "average" ratings the prior is worth.
CREATE FUNCTION bayes_avg(sum_stars numeric, n bigint, global_mean numeric, prior_n integer)
RETURNS numeric LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$$ SELECT round((prior_n * global_mean + sum_stars) / (prior_n + n), 4) $$;

-- One row per movie with everything the analyses need
CREATE VIEW v_movie AS
WITH g AS (SELECT sum(mean_stars * n_ratings) / sum(n_ratings) AS mu   -- from the MV: no 32M-row scan
           FROM mv_movie_stats)
SELECT m.movie_id, m.title, m.release_year, m.imdb_id,
       s.n_ratings, s.mean_stars, s.sd_stars, s.n_likes,
       bayes_avg(s.mean_stars * s.n_ratings, s.n_ratings, (SELECT mu FROM g), 50) AS bayes_stars,
       it.type_code, it.runtime_min,
       ir.avg_rating AS imdb_rating, ir.num_votes AS imdb_votes
FROM movie m
LEFT JOIN mv_movie_stats s ON s.movie_id = m.movie_id
LEFT JOIN imdb_title it    ON it.imdb_id = m.imdb_id
LEFT JOIN imdb_rating ir   ON ir.imdb_id = m.imdb_id;

-- Movie ⋈ genre, the shape most genre analyses start from
CREATE VIEW v_movie_genre AS
SELECT mg.movie_id, g.genre_name
FROM movie_genre mg JOIN genre g USING (genre_id);

-- ---------------------------------------------------------------------
-- refresh_research(): after a load, rebuild the derived statistics and
-- record the data-quality findings (rows are kept; reasons are logged)
-- ---------------------------------------------------------------------
CREATE PROCEDURE refresh_research() LANGUAGE plpgsql AS $$
DECLARE n_issues bigint;
BEGIN
    REFRESH MATERIALIZED VIEW mv_movie_stats;
    REFRESH MATERIALIZED VIEW mv_user_stats;

    DELETE FROM data_issue;

    INSERT INTO data_issue (issue_code, movie_id, detail)
    SELECT 'NO_YEAR', m.movie_id,
           left(m.title, 200) || CASE WHEN m.release_year IS NULL THEN ' → year unknown'
                                      ELSE ' → IMDb year ' || m.release_year END
    FROM movie m
    WHERE m.year_source = 'IMDB' OR m.release_year IS NULL;

    INSERT INTO data_issue (issue_code, movie_id, detail)
    SELECT 'YEAR_MISMATCH', m.movie_id,
           left(m.title, 200) || ' vs IMDb ' || it.start_year
    FROM movie m JOIN imdb_title it USING (imdb_id)
    WHERE m.year_source = 'TITLE' AND abs(m.release_year - it.start_year) > 1;

    INSERT INTO data_issue (issue_code, movie_id, detail)
    SELECT 'SHARED_TMDB', m.movie_id,
           'TMDb ' || m.tmdb_id || ' also used by movie ' ||
           (SELECT string_agg(o.movie_id::text, ', ') FROM movie o
             WHERE o.tmdb_id = m.tmdb_id AND o.movie_id <> m.movie_id)
    FROM movie m
    WHERE m.tmdb_id IN (SELECT tmdb_id FROM movie WHERE tmdb_id IS NOT NULL
                        GROUP BY tmdb_id HAVING count(*) > 1);

    INSERT INTO data_issue (issue_code, movie_id, detail)
    SELECT 'IMDB_MISSING', m.movie_id, 'tt' || lpad(m.imdb_id::text, 7, '0') || ' not in IMDb snapshot'
    FROM movie m
    WHERE NOT EXISTS (SELECT 1 FROM imdb_title it WHERE it.imdb_id = m.imdb_id);

    INSERT INTO data_issue (issue_code, movie_id, detail)
    SELECT 'PRE_RELEASE', m.movie_id,
           count(*) || ' rating(s) before ' || m.release_year || ', earliest ' || min(r.rated_at)::date
    FROM rating r JOIN movie m USING (movie_id)
    WHERE extract(year FROM r.rated_at) < m.release_year - 1
    GROUP BY m.movie_id, m.release_year;

    INSERT INTO data_issue (issue_code, user_id, detail)
    SELECT 'BULK_RATING', user_id,
           max(n) || ' ratings in one second; ' || count(*) || ' such second(s)'
    FROM (SELECT user_id, rated_at, count(*) AS n FROM rating
          GROUP BY user_id, rated_at HAVING count(*) >= 100) b
    GROUP BY user_id;

    INSERT INTO data_issue (issue_code, user_id, detail)
    SELECT 'POWER_USER', user_id, n_ratings || ' ratings'
    FROM mv_user_stats WHERE n_ratings > 5000;

    SELECT count(*) INTO n_issues FROM data_issue;
    RAISE NOTICE 'data issues recorded: %', n_issues;
    ANALYZE;
END $$;

-- ---------------------------------------------------------------------
-- Read-only role (used by the analytics notebook and the injection demo)
-- ---------------------------------------------------------------------
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'movielens_readonly') THEN
        CREATE ROLE movielens_readonly LOGIN PASSWORD 'readonly';
    END IF;
END $$;
GRANT USAGE ON SCHEMA movielens TO movielens_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA movielens TO movielens_readonly;
