# MovieLens 32M — Ratings, Bias & Recommendation Research Database
### FDS Course Project (fourth project) · Design, Normalization & DDL

**DBMS:** PostgreSQL 18 · **Team:** 4 members · **Data:** MovieLens 32M (GroupLens, 1995–2023) linked to IMDb's public datasets (real, public data) · **DDL:** [02_ddl.sql](02_ddl.sql) · **Rules:** [03_logic.sql](03_logic.sql) · **Loader:** [04_load.py](04_load.py)

---

## 1. Problem statement

MovieLens is a film recommender run by GroupLens at the University of Minnesota since 1997. Its public 32M release holds **32,000,204 ratings and 2,000,051 tag applications by 200,948 anonymous users on 87,585 films**, from January 1995 to October 2023. It is the standard benchmark of recommender-systems research, but taken raw it is four flat CSV files with problems a database has to solve:

- **Facts are packed into strings.** The release year sits inside the title ("Toy Story (1995)"), the genres in a pipe-separated list ("Adventure|Animation|Children"). Neither can be queried, indexed or constrained.
- **The rules are implicit.** Half stars did not exist before February 2003; every user has at least 20 ratings; one user rates a film once. Nothing in the files enforces any of this.
- **The links are imperfect.** 618 titles have no year; 36 TMDb ids are shared by two films; 228 IMDb ids no longer exist at IMDb.
- **The interesting questions need joins.** "Does a film's rating fall as it ages?" needs ratings ⋈ films; "do MovieLens users agree with IMDb?" needs a second source; "who rated every Nolan film?" needs ratings ⋈ films ⋈ IMDb credits ⋈ people.

The project loads both sources into a normalized database whose constraints and triggers make the rules explicit, then uses SQL to run a small **research case study** on how people rate: attention inequality, a natural experiment (the half-star switch), the "old films were better" illusion, popularity vs quality, and a recommender built and evaluated in SQL, finished with **k-means segmentation of users**.

### Why this data
- **It is real, large and documented.** 32 million ratings; GroupLens publishes MD5 checksums and a peer-reviewed description (Harper & Konstan, 2015). Large enough that query plans and indexes matter (§8 and `08_optimizer.sql`).
- **It is naturally relational.** Users, films, ratings (M:N with attributes), tags (ternary), genres (M:N), and through `imdbId` a second source: IMDb titles, ratings, directors.
- **It connects to other courses.** Statistics (paired tests, difference-in-differences, regression with fixed effects), machine learning (collaborative filtering, k-means, train/test evaluation), economics of attention (Gini, long tail).
- **It is checkable.** The top films, the Coen brothers' co-directions and the half-star switch all show up where they should.

## 2. Business rules (these drive every constraint)

| # | Rule | Enforced by |
|---|---|---|
| BR-1 | Stars run from 0.5 to 5.0 in half-star steps | `CHECK` on `rating.stars` |
| BR-2 | A user rates a film at most once (re-rating overwrites); a user applies a tag to a film once | PK `(user_id, movie_id)`; PK `(user_id, movie_id, tag_id)` |
| BR-3 | A rating uses the star scale in force at that moment: whole stars (1–5) before the switch, half stars after. Scales never overlap | `rating_scale` with a **GiST exclusion constraint** on `tstzrange`; **statement-level trigger** with a transition table |
| BR-4 | Every user in the dataset has rated at least 20 films (GroupLens' sampling rule) | **Statement-level triggers** on INSERT and DELETE, emulating SQL's unimplemented `CREATE ASSERTION` |
| BR-5 | A rating never moves to another user or film, and a re-rating is not older than the rating it replaces | Row-level `BEFORE UPDATE` trigger |
| BR-6 | A film's release year comes from its title; if the title has none, from IMDb; the source is recorded | `year_source` + `CHECK ((release_year IS NULL) = (year_source IS NULL))` |
| BR-7 | A film has one IMDb id, and no two films share one; TMDb ids may repeat (known mapping errors) | `UNIQUE (imdb_id)`; `tmdb_id` only indexed |
| BR-8 | Ratings and tags happen inside the dataset's window (1995-01-01 to the 2023-10-13 snapshot) | `CHECK`s on `rated_at`, `tagged_at` |
| BR-9 | Genres come from a fixed vocabulary of 19 | `genre` lookup + FK from `movie_genre` |
| BR-10 | A tag is trimmed, non-empty text; tags differing only in case are one concept | `CHECK (tag_text = btrim(tag_text))`; generated column `tag_key = lower(tag_text)` |
| BR-11 | Statistics (counts, means, Bayesian averages) are derived from ratings, never stored as base data | Materialized views `mv_movie_stats`, `mv_user_stats`; view `v_movie` |
| BR-12 | Suspicious but real records are kept, and the reason is recorded | `data_issue` + `issue_type`, filled by `refresh_research()` |

### What the real data taught us about the rules
- **The half-star switch is in the data, to the second.** No rating before **2003-02-18 21:34:27 UTC** uses a half star or 0.5; after it, half stars appear at once. The loader reads the switch from the data and writes it into `rating_scale`; BR-3 then checks all 32M rows against it.
- **The README is incomplete.** It lists 18 genres including "Children's"; the data uses "Children" and also **IMAX** (195 films). The vocabulary follows the data.
- **Years are not always in the title.** 618 titles have no "(yyyy)" (e.g. *Terrible Joe Moran*), and one has a typo, "(1983))". IMDb's start year fills 611 of them; 7 stay unknown.
- **Duplicate titles are mostly different films.** 203 titles repeat ("Aladdin (1992)" is both the Disney film and a different animation), so a title is no key. Two films sharing a **TMDb** id is the real error (*Clockstoppers* appears twice with different IMDb ids).
- **Some ratings come before release** (festival screenings, or a wrong year): 244 ratings on 21 films more than a year early. Kept, and logged as `PRE_RELEASE`.
- **Some users entered hundreds of ratings in one second** (up to 279): imports or onboarding screens. Kept, and logged as `BULK_RATING`; one user has 33,332 ratings (`POWER_USER`).
- **The IMDb side has moved on.** 228 of MovieLens' IMDb ids are no longer in IMDb (merged titles). This is why `movie.imdb_id` has **no foreign key** to `imdb_title`: the link is MovieLens' fact, the IMDb table is a dated snapshot, and a FK would force us either to delete real films or to invent IMDb rows.

## 3. Enhanced ER model

### 3.1 Entities and attributes

| Entity | Key | Attributes | Notes |
|---|---|---|---|
| USER | user_id | — | Anonymous by design: the dataset gives an id and nothing else |
| MOVIE | movie_id | title, release_year, year_source, imdb_id (unique), tmdb_id | |
| GENRE | genre_id | genre_name (unique) | Lookup |
| TAG | tag_id | tag_text (unique), tag_key (derived: lower(tag_text)) | Derived attribute, stored as a generated column |
| RATING_SCALE | scale_code | valid_from, valid_to, step, min_stars | Temporal lookup: one scale at any instant |
| IMDB_TITLE | imdb_id | type_code, primary_title, start_year, runtime_min, is_adult | Second source |
| IMDB_RATING | imdb_id | avg_rating, num_votes | Weak 1:1 dependent of IMDB_TITLE |
| PERSON | person_id | full_name, birth_year, death_year | Directors only |
| TITLE_TYPE | type_code | description, is_feature | Lookup |
| DATA_SOURCE, ISSUE_TYPE, DATA_ISSUE | | | Provenance and data-quality log |

### 3.2 Relationships: cardinality and participation

| Relationship | Between | Cardinality | Participation | Attributes |
|---|---|---|---|---|
| RATES | USER – MOVIE | M:N | USER total (≥ 20, BR-4); MOVIE partial (3,153 films are only tagged) | stars, rated_at |
| TAGS | USER – MOVIE – TAG | ternary M:N:P | all partial | tagged_at |
| HAS_GENRE | MOVIE – GENRE | M:N | MOVIE partial (7,080 have none) | — |
| LINKS_TO | MOVIE – IMDB_TITLE | 1:1 | MOVIE partial in practice (228 dangling), IMDB_TITLE total (we load only linked titles) | — |
| DIRECTED | PERSON – IMDB_TITLE | M:N | IMDB_TITLE partial | billing order |
| HAS_RATING | IMDB_TITLE – IMDB_RATING | 1:1 | IMDB_RATING total (weak) | — |

### 3.3 EER constructs used
- **Ternary relationship:** TAGS (user, film, tag). It cannot be split into binary relationships without losing *who* applied *which* tag to *which* film.
- **Derived attributes:** `tag_key` (generated column); release year when it comes from IMDb; every statistic (BR-11), kept in views instead.
- **Temporal (valid-time) entity:** RATING_SCALE, with non-overlap enforced by an exclusion constraint.
- **Weak entity:** IMDB_RATING, identified by its title.
- **Two sources, one model:** the IMDb side is connected by a natural key (imdb_id) instead of a surrogate, because it is how the two datasets meet.

### 3.4 Diagram (relational / crow's-foot view)

```
 data_source     rating_scale (BR-3, exclusion)      issue_type ──< data_issue >── movie / ml_user

 ml_user ──<  rating  >── movie ──< movie_genre >── genre
    │       (32M rows)      │
    └──< tag_application >──┤
              │             │ imdb_id (no FK: snapshot)
             tag            ▼
                        imdb_title ──1:1── imdb_rating
                            │    └── title_type
                     title_director >── person
```

## 4. ER → relational mapping (Elmasri–Navathe steps)

1. **Strong entities** → `ml_user`, `movie`, `genre`, `tag`, `imdb_title`, `person`, lookups.
2. **Weak entity** → `imdb_rating` (PK = owner's key, FK with `ON DELETE CASCADE`).
3. **1:1** LINKS_TO → foreign-key-style column `movie.imdb_id` (unique), on the partial side.
4. **M:N** RATES → `rating (user_id, movie_id)` carrying stars and time; HAS_GENRE → `movie_genre`; DIRECTED → `title_director` with billing order.
5. **Ternary** TAGS → `tag_application (user_id, movie_id, tag_id)`.
6. **Multivalued attribute** genres ("A|B|C" in the CSV) → `movie_genre` rows.

### Final relational schema (16 base tables)

```
data_source(source_code, description, url, snapshot_on)
genre(genre_id, genre_name)
title_type(type_code, description, is_feature)
rating_scale(scale_code, valid_from, valid_to, step, min_stars)
imdb_title(imdb_id, type_code→title_type, primary_title, start_year, runtime_min, is_adult)
imdb_rating(imdb_id→imdb_title, avg_rating, num_votes)
person(person_id, full_name, birth_year, death_year)
title_director(imdb_id→imdb_title, person_id→person, billing)
movie(movie_id, title, release_year, year_source, imdb_id UNIQUE, tmdb_id)
movie_genre(movie_id→movie, genre_id→genre)
ml_user(user_id)
rating(user_id→ml_user, movie_id→movie, stars, rated_at)
tag(tag_id, tag_text UNIQUE, tag_key)
tag_application(user_id→ml_user, movie_id→movie, tag_id→tag, tagged_at)
issue_type(issue_code, description)          data_issue(issue_id, issue_code→issue_type, movie_id, user_id, detail)
```
Analytics tables (07): `rec_item`, `rec_neighbor`, `rec_test_user`, `rec_list`, `segment`, `user_segment`.

## 5. Normalization: from the CSV rows to BCNF

### 5.0 Starting point: the flat record
Joining the four files gives one wide row per rating:
`(userId, movieId, title_with_year, genres_list, imdbId, tmdbId, rating, timestamp, tag?, tag_timestamp?)`.

### 5.1 Functional dependencies
- movieId → title, year, genres, imdbId, tmdbId
- imdbId → movieId (both are keys of a film)
- (userId, movieId) → rating, timestamp
- (userId, movieId, tag) → tag_timestamp
- tag_text → tag_key
- imdbId → titleType, runtime, IMDb rating, votes; titleType → is_feature
- rated_at → star scale in force (through `rating_scale`)

### 5.2 1NF
`genres_list` is multivalued → `movie_genre` rows. `title_with_year` is a composite of two facts → `title` + `release_year`.

### 5.3 2NF: remove partial dependencies
The key of the wide row is (userId, movieId[, tag]). Title, year, links depend on movieId alone → `movie`. Tag time depends on (user, movie, tag), not on the rating → `tag_application`.

### 5.4 3NF: remove transitive dependencies
movieId → imdbId → IMDb attributes → `imdb_title`, `imdb_rating`. titleType → is_feature → `title_type`. source → snapshot date → `data_source` (otherwise repeated on 32M rows).

### 5.5 BCNF check
Every non-trivial FD's left side is a key of its table. In `movie`, both `movie_id` and `imdb_id` are candidate keys, so `imdb_id → title` is not a violation. In `tag`, `tag_text → tag_key` holds with `tag_text` a candidate key, and `tag_key` is generated, so it can never disagree. All tables are in BCNF.

### 5.6 Deliberate decisions
- **No FK from `movie.imdb_id`** (see §2, "what the data taught us").
- **`tmdb_id` is not unique**: making it unique would reject real data, or force us to guess which of two films is wrong.
- **No statistics in base tables** (BR-11): a stored average would go stale on every new rating; materialized views make the refresh explicit (06_demo shows one going stale).
- **Users have no attributes.** The dataset gives none; we do not invent demographics.

## 6. Analytics plan and findings

### 6.1 Queries ([05_queries.sql](05_queries.sql))
| Query | Question | FDS concepts |
|---|---|---|
| Q1 | Best film per genre, honestly ranked | Window functions in partitions, Bayesian average |
| Q2 | Who has seen every Christopher Nolan film? | Relational division (double NOT EXISTS), joins across both sources |
| Q3 | How connected are directors by co-directing? | Recursive CTE, breadth-first search with UNION (set semantics bound the work) |
| Q4 | What do people call a film? | LATERAL top-N, generated columns |
| Q5 | Where do MovieLens and IMDb disagree? | INTERSECT / EXCEPT, PERCENT_RANK |

### 6.2 Research statistics, recommender, k-means ([07_analytics.sql](07_analytics.sql), notebook)
A1 attention inequality · A2–A3 the half-star natural experiment (with a placebo date and difference-in-differences) · A4–A5 old films and survivorship (between-film vs within-film) · A6 popularity vs quality · A7 MovieLens vs IMDb · A8 genres · A9 rating drift with experience · R1–R2 item-to-item recommender with a temporal holdout · user features → k-means → S1–S2.

### 6.3 Query optimization ([08_optimizer.sql](08_optimizer.sql))
The catalog statistics, selectivity estimates by hand vs the optimizer vs the truth, the independence assumption failing (and extended statistics fixing it), join-size estimation, join order on a 4-relation query (24 left-deep / 120 binary trees), access-path choice, physical order and BRIN, and materialized aggregates.

### 6.4 Findings (full 32M load; notebook and psql output)
**Queries (05, 36 s in total)**
- **Q1:** *Band of Brothers* tops Action, Drama and War, and *The Shawshank Redemption* tops Crime. The Bayesian average moves small-sample films down: *Over the Garden Wall* (1,397 ratings) is first in Adventure by raw mean but second after shrinkage.
- **Q2:** of 102,205 users who rated any of Nolan's 12 feature films, **63** rated all of them, and they rate him *lower* (3.92 vs 4.07). Completists include the people who keep watching a director they have doubts about.
- **Q3:** Ethan Coen reaches 51 directors in one step (through anthology films such as *To Each His Own Cinema*: Lynch, Wenders, Loach), 373 in two (Godard, Herzog, Scorsese) and 2,551 within six.
- **Q4:** the most-tagged films are described by structure, not genre: "nonlinear", "twist ending", "thought-provoking".
- **Q5:** of the films well known on both sites, 470 are in both top fifths, 104 only in IMDb's and 157 only in MovieLens'. IMDb likes *Home Alone*, *Titanic* and *Dumb & Dumber* more; MovieLens likes *Primer* and *Coherence* more.

**Research case study (07 + notebook)**
- **Long tail:** the top 1% of films get **54.8%** of ratings and the top 10% get 95.7%; 62% of films have fewer than 10 ratings. Gini **0.952**.
- **Half-star switch (natural experiment):** half stars took 40.7% of ratings after 18 Feb 2003. Following the same 2,643 users, their mean rose +0.046 stars against +0.026 at a placebo date: difference-in-differences **+0.020 stars**. The shape changed; the level barely moved.
- **Old films:** films over 40 years old average 3.80 stars against 3.42 in the release year, but the *same* film falls **−0.0185 stars a year** as it ages (2,126 films). The old-film premium is **survivorship**.
- **Popularity:** corr(ln n, mean) = 0.26. MovieLens and IMDb agree: Pearson **0.92** over 11,535 films.
- **Genres:** Film-Noir best and least divisive (3.92, SD 0.91); Horror worst and most divisive (3.31, SD 1.13).
- **Experience:** a heavy user's first 20 ratings sit +0.30 above their own mean; ratings after the 500th sit −0.08 below.
- **Recommender in SQL:** item-kNN hit rate @10 **69.9%** against POPULAR 52.1% and TOP_RATED 43.1% (459 test users, ratings after 1 Jan 2021 hidden). Bootstrap difference **+17.9 points, 95% CI [+13.1, +22.9]**. kNN also recommends 407 distinct films against 144.
- **Segments (k-means, k = 4, silhouette 0.18):** Cinephiles (42,832; ~466 ratings each), **1990s Pioneers** (61,214), Easy Pleasers (63,425; 4.10 stars), Tough Critics (33,477; 3.27 stars, SD 1.24). The Pioneers almost never use half stars: **91% joined before the 2003 switch**. k-means rediscovered BR-3 without seeing a date.
- **Evaluation bias:** Cinephiles are 21% of users but 75% of recommender test users, and the Pioneers are absent. kNN wins in every segment it can be tested on (Tough Critics 61.9% vs 28.6%).

**Query optimization (08, 89 s)**
- **Statistics are samples:** ANALYZE's 30,000-row sample estimates V(movie_id) = 7,558 and V(user_id) = 31,989; the truth is 84,432 and 200,948 (about 11× and 6× too low). The exact `count(DISTINCT …)` over 32M rows took **39 minutes** on our laptop; the materialized views give the same answer instantly.
- **Selectivity by hand matches the optimizer:** stars = 5 (MCV) 4,508,852 by hand vs 4,596,577 true; rated_at ≥ 2020 (histogram) 4,677,921 vs 4,635,230.
- **Independence fails:** "half stars before 2003" is empty (BR-3), but 31% × the default 1/3 predicts **3.3 million** rows. Extended statistics with a 1,000-entry joint MCV list bring the estimate to **1**.
- **The optimizer's default plan was the slowest** (~10 s): an index nested loop over 353 noir films that fetches ~300K random pages from a table stored in user order. With `effective_cache_size` set to fit this 8 GB machine, the optimizer itself picks a hash-join plan (~4 s). Forcing the written join order (`join_collapse_limit = 1`) builds intermediates of 4.6M and 12.8M rows.
- **Indexes:** movie_id lookup with `ix_rating_movie` 0.8 s against 3.6 s via the PK (23,848 index searches, skip-scan style). BRIN on time-ordered data is **24 kB** against a 62 MB B-tree, and answers a range query in 11 ms against 398 ms on unordered data. The materialized view answers "top films" in 59 ms against 6.9 s.

## 7. Presentation split for 4 members (20:00)
| Member | Part | Time |
|---|---|---|
| M1 | Problem and data (32M ratings + IMDb), business rules, what the data taught us (no-year titles, shared TMDb ids, bulk ratings), EER and BCNF | 5:00 |
| M2 | DDL and logic: GiST exclusion on `rating_scale`, BR-3/BR-4 statement triggers, materialized views; **live demo** `06_demo.sql`; Q1–Q5 highlights | 5:00 |
| M3 | Query optimizer on 32M rows (`08_optimizer.sql`): statistics are samples, selectivity by hand, independence and extended statistics, the slow default plan, BRIN | 5:00 |
| M4 | Research case study: long tail, half-star natural experiment (DiD + placebo), survivorship, SQL recommender with bootstrap CI, k-means segments rediscovering BR-3; limitations | 5:00 |

Other courses drawn on: statistics (paired t, difference-in-differences, bootstrap, Gini), machine learning (k-means, silhouette, PCA, collaborative filtering, temporal holdout evaluation), econometrics (natural experiments, placebo tests, fixed effects in A9).

## 8. Files and run order
`run_all.ps1` → `data/fetch.py` → `02_ddl.sql` → `03_logic.sql` → `04_load.py` → `07_analytics.sql`. Then `05_queries.sql`, `06_demo.sql`, `08_optimizer.sql` with psql, and the notebook. On our laptop (8 GB RAM, slow disk) `run_all.ps1` takes about 1 h 55 min, plus 22 min for the notebook:

| Step | Time |
|---|---|
| IMDb join | ~2 min |
| ratings COPY | 15 min |
| keys, FKs and index rebuild | 15 min |
| tags | 4 min |
| `refresh_research()` | 23 min |
| `07_analytics.sql` (A1–A9 and `build_recommender()`) | ~53 min |
| notebook | ~22 min |

## 9. Decisions taken
- **Ratings are streamed straight into `rating`**, with its keys, FKs and index dropped during the COPY and re-added afterwards. Staging in a temporary table was tried first and was far slower on this disk (each scan of the 32M-row staging table took minutes).
- **Base data and research layer commit separately.** The base load (steps 1–4) is one transaction. `refresh_research()` (materialized views, `data_issue`) runs after it, so a failure there does not throw away 35 minutes of loading.
- **No FK from `movie.imdb_id` to `imdb_title`:** 228 linked ids are not in the current IMDb snapshot. They are logged as IMDB_MISSING instead of rejecting real films.
- **The recommender is bounded deliberately:** a catalogue of the 2,000 most-liked films, co-likes from a 1-in-4 user sample capped at each user's 100 most recent likes, and the top 50 neighbours per film. Test users are `user_id % 10 = 3` with ≥ 20 ratings before 2021 and ≥ 5 catalogue likes after.
- **Segments are named by rules on the centroids**, not by k-means' label numbers, and the "1990s Pioneers" name was checked against the users' dates (§7 of the notebook).
- **All dates are UTC** (`SET timezone = 'UTC'` in every script): the dataset's timestamps are UTC, and the year of a rating must not depend on the presenter's laptop.
