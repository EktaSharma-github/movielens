-- =====================================================================
-- MovieLens 32M — Ratings, Bias & Recommendation Research Database
-- 02_ddl.sql : schema, keys, CHECKs, and reference data
-- Target: PostgreSQL 18 (15+). Re-runnable: drops and recreates the schema.
-- Design rationale: 01_design.md (BR-n = business rule n)
-- =====================================================================

SET client_min_messages = warning;   -- hide the DROP ... CASCADE notices
DROP SCHEMA IF EXISTS movielens CASCADE;
CREATE SCHEMA movielens;
SET search_path = movielens;
CREATE EXTENSION IF NOT EXISTS btree_gist;   -- range exclusion on the rating scale (BR-3)

-- ---------------------------------------------------------------------
-- 1. Provenance and lookup tables
-- ---------------------------------------------------------------------
CREATE TABLE data_source (
    source_code   varchar(10) PRIMARY KEY,
    description   varchar(100) NOT NULL,
    url           varchar(120) NOT NULL,
    snapshot_on   date NOT NULL          -- FD: source → snapshot date (not repeated on 32M rows)
);

CREATE TABLE genre (
    genre_id    smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    genre_name  varchar(20) NOT NULL UNIQUE      -- BR-9: the fixed MovieLens vocabulary
);

CREATE TABLE title_type (
    type_code    varchar(14) PRIMARY KEY,       -- IMDb titleType
    description  varchar(40) NOT NULL,
    is_feature   boolean NOT NULL               -- FD: type → whether it is a feature film
);

-- BR-3: which star step was allowed when. MovieLens switched from whole to
-- half stars in February 2003; the switch date is taken from the data (the
-- first half-star rating), see 01_design.md §3.
CREATE TABLE rating_scale (
    scale_code  varchar(5) PRIMARY KEY CHECK (scale_code IN ('WHOLE', 'HALF')),
    valid_from  timestamptz NOT NULL,
    valid_to    timestamptz NOT NULL,          -- exclusive
    step        numeric(2,1) NOT NULL CHECK (step IN (0.5, 1.0)),
    min_stars   numeric(2,1) NOT NULL,
    CHECK (valid_from < valid_to),
    EXCLUDE USING gist (tstzrange(valid_from, valid_to) WITH &&)   -- one scale at any instant
);

-- ---------------------------------------------------------------------
-- 2. IMDb side (external enrichment, linked through movie.imdb_id)
-- ---------------------------------------------------------------------
CREATE TABLE imdb_title (
    imdb_id        integer PRIMARY KEY,                    -- tt0114709 → 114709
    type_code      varchar(14) NOT NULL REFERENCES title_type,
    primary_title  varchar(450) NOT NULL,
    start_year     smallint CHECK (start_year BETWEEN 1870 AND 2030),
    runtime_min    integer CHECK (runtime_min > 0),
    is_adult       boolean NOT NULL
);

CREATE TABLE imdb_rating (
    imdb_id     integer PRIMARY KEY REFERENCES imdb_title ON DELETE CASCADE,
    avg_rating  numeric(3,1) NOT NULL CHECK (avg_rating BETWEEN 1 AND 10),
    num_votes   integer NOT NULL CHECK (num_votes >= 5)   -- IMDb publishes only rated titles
);

CREATE TABLE person (
    person_id   integer PRIMARY KEY,                       -- nm0000001 → 1
    full_name   varchar(200) NOT NULL,
    birth_year  smallint,
    death_year  smallint,
    CHECK (death_year IS NULL OR birth_year IS NULL OR death_year >= birth_year)
);

CREATE TABLE title_director (
    imdb_id     integer  NOT NULL REFERENCES imdb_title ON DELETE CASCADE,
    person_id   integer  NOT NULL REFERENCES person,
    billing     smallint NOT NULL CHECK (billing >= 1),    -- order in IMDb's credit list
    PRIMARY KEY (imdb_id, person_id),
    UNIQUE (imdb_id, billing)
);
CREATE INDEX ix_director_person ON title_director (person_id);

-- ---------------------------------------------------------------------
-- 3. MovieLens side
-- ---------------------------------------------------------------------
CREATE TABLE movie (
    movie_id      integer PRIMARY KEY,                     -- MovieLens id (movielens.org/movies/1)
    title         varchar(300) NOT NULL CHECK (title = btrim(title) AND title <> ''),
    release_year  smallint CHECK (release_year BETWEEN 1870 AND 2030),
    -- BR-6: where the year came from. The title suffix "(1995)" is MovieLens' own;
    -- 618 titles lack it and 611 of those get IMDb's start year instead.
    year_source   varchar(5) CHECK (year_source IN ('TITLE', 'IMDB')),
    -- BR-7: links.csv. imdb_id is unique; tmdb_id is NOT (36 TMDb ids are shared
    -- by two MovieLens movies, a known mapping error), so it is no key.
    -- No FK to imdb_title: 228 linked ids no longer exist in today's IMDb
    -- (merged titles); the link is MovieLens' fact, imdb_title is a snapshot.
    imdb_id       integer NOT NULL UNIQUE,
    tmdb_id       integer,
    CHECK ((release_year IS NULL) = (year_source IS NULL))
);
CREATE INDEX ix_movie_tmdb ON movie (tmdb_id);

CREATE TABLE movie_genre (
    movie_id  integer  NOT NULL REFERENCES movie ON DELETE CASCADE,
    genre_id  smallint NOT NULL REFERENCES genre,
    PRIMARY KEY (movie_id, genre_id)
    -- "(no genres listed)" is the absence of rows, not a genre
);
CREATE INDEX ix_movie_genre_genre ON movie_genre (genre_id);

-- Users are anonymous: the dataset gives an id and nothing else
CREATE TABLE ml_user (
    user_id  integer PRIMARY KEY
);

-- 32 million rows. Keys and FKs are named: 04_load.py drops and re-adds them
-- around the bulk insert (building an index once is far cheaper than
-- maintaining it row by row).
CREATE TABLE rating (
    user_id   integer NOT NULL CONSTRAINT fk_rating_user  REFERENCES ml_user,
    movie_id  integer NOT NULL CONSTRAINT fk_rating_movie REFERENCES movie,
    -- BR-1: 0.5 to 5 stars in half-star steps
    stars     numeric(2,1) NOT NULL CONSTRAINT ck_rating_stars
              CHECK (stars BETWEEN 0.5 AND 5.0 AND stars * 2 = trunc(stars * 2)),
    rated_at  timestamptz NOT NULL CONSTRAINT ck_rating_time
              CHECK (rated_at >= '1995-01-01' AND rated_at < '2023-10-14'),
    -- BR-2: one rating per user and movie (re-rating overwrites in MovieLens)
    CONSTRAINT pk_rating PRIMARY KEY (user_id, movie_id)
);
-- "All ratings of a movie": the PK (user_id, movie_id) cannot serve it,
-- because movie_id is not its leading column
CREATE INDEX ix_rating_movie ON rating (movie_id);

CREATE TABLE tag (
    tag_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tag_text  varchar(300) NOT NULL UNIQUE CHECK (tag_text = btrim(tag_text) AND tag_text <> ''),  -- BR-10
    -- "Sci-Fi", "sci-fi" and "sci-fi " are one concept: the key is derived, so it
    -- cannot disagree with tag_text (generated, not typed in)
    tag_key   varchar(300) GENERATED ALWAYS AS (lower(tag_text)) STORED
);
CREATE INDEX ix_tag_key ON tag (tag_key);

CREATE TABLE tag_application (
    user_id    integer NOT NULL REFERENCES ml_user,
    movie_id   integer NOT NULL REFERENCES movie,
    tag_id     integer NOT NULL REFERENCES tag,
    tagged_at  timestamptz NOT NULL CHECK (tagged_at >= '1995-01-01' AND tagged_at < '2023-10-14'),
    PRIMARY KEY (user_id, movie_id, tag_id)
);
CREATE INDEX ix_tagapp_movie ON tag_application (movie_id);
CREATE INDEX ix_tagapp_tag   ON tag_application (tag_id);

-- ---------------------------------------------------------------------
-- 4. Data-quality findings: rows that are real but suspicious are kept,
--    and the reason is recorded here (never silently dropped or fixed)
-- ---------------------------------------------------------------------
CREATE TABLE issue_type (
    issue_code   varchar(20) PRIMARY KEY,
    description  varchar(120) NOT NULL
);

CREATE TABLE data_issue (
    issue_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    issue_code  varchar(20) NOT NULL REFERENCES issue_type,
    movie_id    integer REFERENCES movie ON DELETE CASCADE,
    user_id     integer REFERENCES ml_user ON DELETE CASCADE,
    detail      varchar(300) NOT NULL,
    CHECK (movie_id IS NOT NULL OR user_id IS NOT NULL)
);
CREATE INDEX ix_issue_code ON data_issue (issue_code);

-- ---------------------------------------------------------------------
-- 5. Reference data
-- ---------------------------------------------------------------------
INSERT INTO data_source VALUES
 ('ML32M', 'MovieLens 32M (GroupLens, University of Minnesota)',
           'https://files.grouplens.org/datasets/movielens/ml-32m.zip', '2023-10-13'),
 ('IMDB',  'IMDb non-commercial datasets (title.basics, title.ratings, title.crew, name.basics)',
           'https://datasets.imdbws.com/', '2026-10-30');

-- README lists 18 genres; the data also uses IMAX, and "Children" (not "Children's")
INSERT INTO genre (genre_name) VALUES
 ('Action'), ('Adventure'), ('Animation'), ('Children'), ('Comedy'), ('Crime'),
 ('Documentary'), ('Drama'), ('Fantasy'), ('Film-Noir'), ('Horror'), ('IMAX'),
 ('Musical'), ('Mystery'), ('Romance'), ('Sci-Fi'), ('Thriller'), ('War'), ('Western');

INSERT INTO title_type VALUES
 ('movie',        'Feature film',            true),
 ('tvMovie',      'Made-for-TV film',        true),
 ('video',        'Direct-to-video film',    true),
 ('short',        'Short film',              false),
 ('tvShort',      'TV short',                false),
 ('tvSpecial',    'TV special',              false),
 ('tvEpisode',    'TV episode',              false),
 ('tvMiniSeries', 'TV mini-series',          false),
 ('tvSeries',     'TV series',               false),
 ('tvPilot',      'TV pilot',                false),
 ('videoGame',    'Video game',              false);

-- valid_to of WHOLE / valid_from of HALF are set by 04_load.py from the data
INSERT INTO rating_scale VALUES
 ('WHOLE', '1995-01-01', '2003-02-18', 1.0, 1.0),
 ('HALF',  '2003-02-18', '2100-01-01', 0.5, 0.5);

INSERT INTO issue_type VALUES
 ('NO_YEAR',        'Title has no "(yyyy)" suffix; year taken from IMDb or left unknown'),
 ('YEAR_MISMATCH',  'Title year and IMDb start year differ by more than one year'),
 ('SHARED_TMDB',    'Two MovieLens movies point to the same TMDb id'),
 ('IMDB_MISSING',   'Linked IMDb id is not in the current IMDb snapshot'),
 ('PRE_RELEASE',    'Rated more than a year before the release year'),
 ('BULK_RATING',    'User entered 100+ ratings within the same second (import or onboarding)'),
 ('POWER_USER',     'User has more than 5,000 ratings');
