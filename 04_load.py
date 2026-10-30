"""Load MovieLens 32M and the IMDb enrichment (data/raw/, from data/fetch.py) into the schema.

Steps 1-4 run in one transaction (all or nothing):
  1. Movies and links: split the "(1995)" suffix off each title; titles without one
     take IMDb's start year (01_design.md §3). Genres become movie_genre rows.
  2. IMDb: only the titles MovieLens links to, their ratings, directors, and those
     directors' names (the IMDb files are streamed, never loaded whole).
  3. Ratings: one pass reads the users and the half-star switch date off the file
     (BR-3); a second streams the 32M rows into rating with ONE COPY, its keys and
     index dropped, so the statement-level triggers check all 32M rows at once.
  4. Tags: trimmed, deduplicated per user and movie.
  5. Commit, then CALL refresh_research() (statistics and the data-quality log) in its
     own transaction: derived data only, so it can be re-run without reloading.

Rows that break a rule are not silently dropped: they go to data/work/rejected_rows.csv
with the reason, and are counted.

Usage:  .venv\\Scripts\\python 04_load.py
Connection: PGHOST / PGUSER / PGPASSWORD / PGDATABASE (defaults: localhost, postgres, postgres, movielens)
"""
import csv
import datetime as dt
import gzip
import os
import re
import time

import psycopg

HERE = os.path.dirname(os.path.abspath(__file__))
ML = os.path.join(HERE, "data", "raw", "ml-32m")
IMDB = os.path.join(HERE, "data", "raw", "imdb")
WORK = os.path.join(HERE, "data", "work")
YEAR_SUFFIX = re.compile(r"^(.*\S)\s*\((\d{4})\)$")
EPOCH = dt.date(1970, 1, 1)
# ML_SAMPLE=n loads only the first ~n ratings (whole users) and their tags: a
# dev database for testing every SQL file in seconds instead of ~40 minutes
SAMPLE = int(os.environ.get("ML_SAMPLE", "0"))
csv.field_size_limit(10_000_000)


def connect():
    return psycopg.connect(
        host=os.environ.get("PGHOST", "localhost"),
        user=os.environ.get("PGUSER", "postgres"),
        password=os.environ.get("PGPASSWORD", "postgres"),
        dbname=os.environ.get("PGDATABASE", "movielens"),
        options="-c search_path=movielens -c timezone=UTC",
    )


def tsv(name):
    """Stream an IMDb .tsv.gz as dicts; IMDb writes NULL as \\N and does not quote."""
    with gzip.open(os.path.join(IMDB, name), "rt", encoding="utf-8", newline="") as f:
        header = f.readline().rstrip("\n").split("\t")
        for line in f:
            vals = line.rstrip("\n").split("\t")
            yield {k: (None if v == "\\N" else v) for k, v in zip(header, vals)}


def ml_csv(name):
    with open(os.path.join(ML, name), encoding="utf-8", newline="") as f:
        yield from csv.DictReader(f)


def rating_lines():
    """ratings.csv without its header; with ML_SAMPLE, stop at the first user boundary after n lines."""
    with open(os.path.join(ML, "ratings.csv"), encoding="ascii") as f:
        next(f)
        last = None
        for i, line in enumerate(f):
            if SAMPLE and i >= SAMPLE:
                u = line.split(",", 1)[0]
                if last is not None and u != last:
                    return
                last = u
            yield line


def imdb_num(tconst):           # tt0114709 / nm0000001 → 114709 / 1
    return int(tconst[2:])


class Log:
    def __init__(self):
        self.t0 = time.time()

    def __call__(self, msg):
        print(f"[{time.time() - self.t0:7.1f}s] {msg}", flush=True)


def main():
    log = Log()
    os.makedirs(WORK, exist_ok=True)
    rejected = []

    # ------------------------------------------------------------------
    # 1. Movies, links, genres (in memory: 87K rows)
    # ------------------------------------------------------------------
    links = {int(r["movieId"]): r for r in ml_csv("links.csv")}
    movies, movie_genres = [], []
    for r in ml_csv("movies.csv"):
        mid = int(r["movieId"])
        raw = r["title"].strip()
        m = YEAR_SUFFIX.match(raw)
        title, year = (m.group(1), int(m.group(2))) if m else (raw, None)
        ln = links[mid]
        movies.append([mid, title, year, "TITLE" if year else None,
                       int(ln["imdbId"]), int(ln["tmdbId"]) if ln["tmdbId"] else None])
        if r["genres"] != "(no genres listed)":
            movie_genres += [(mid, g) for g in r["genres"].split("|")]
    imdb_ids = {mv[4] for mv in movies}
    log(f"movies {len(movies):,}; titles with a year suffix {sum(1 for mv in movies if mv[2]):,}")

    # ------------------------------------------------------------------
    # 2. IMDb: stream and keep only what MovieLens links to
    # ------------------------------------------------------------------
    titles = {}
    for r in tsv("title.basics.tsv.gz"):
        i = imdb_num(r["tconst"])
        if i in imdb_ids:
            titles[i] = (i, r["titleType"], r["primaryTitle"],
                         int(r["startYear"]) if r["startYear"] else None,
                         int(r["runtimeMinutes"]) if r["runtimeMinutes"] and r["runtimeMinutes"].isdigit()
                         and int(r["runtimeMinutes"]) > 0 else None,
                         r["isAdult"] == "1")
    ratings_imdb = [(imdb_num(r["tconst"]), r["averageRating"], int(r["numVotes"]))
                    for r in tsv("title.ratings.tsv.gz") if imdb_num(r["tconst"]) in titles]
    directors = []
    for r in tsv("title.crew.tsv.gz"):
        i = imdb_num(r["tconst"])
        if i in titles and r["directors"]:
            seen = set()
            for nm in r["directors"].split(","):
                p = imdb_num(nm)
                if p not in seen:
                    seen.add(p)
                    directors.append((i, p, len(seen)))
    need = {d[1] for d in directors}
    people = {}
    for r in tsv("name.basics.tsv.gz"):
        p = imdb_num(r["nconst"])
        if p in need:
            people[p] = (p, r["primaryName"] or "(unknown)",
                         int(r["birthYear"]) if r["birthYear"] else None,
                         int(r["deathYear"]) if r["deathYear"] else None)
    for i, p, b in directors:
        if p not in people:                 # credited but absent from name.basics
            people[p] = (p, "(unknown)", None, None)
    log(f"IMDb: {len(titles):,} titles, {len(ratings_imdb):,} ratings, "
        f"{len(directors):,} director credits, {len(people):,} people")

    # Year fallback (BR-6): a title without "(yyyy)" takes IMDb's start year
    for mv in movies:
        if mv[2] is None and mv[4] in titles and titles[mv[4]][3]:
            mv[2], mv[3] = titles[mv[4]][3], "IMDB"

    with connect() as conn, conn.cursor() as cur:
        cur.execute("SET maintenance_work_mem = '1GB'")
        cur.execute("SET work_mem = '256MB'")

        types = {t for (t,) in cur.execute("SELECT type_code FROM title_type")}
        unknown = {t[1] for t in titles.values()} - types
        if unknown:
            raise SystemExit(f"IMDb title types not in title_type: {unknown}")

        with cur.copy("COPY imdb_title FROM STDIN") as cp:
            for t in titles.values():
                cp.write_row(t)
        with cur.copy("COPY imdb_rating FROM STDIN") as cp:
            for t in ratings_imdb:
                cp.write_row(t)
        with cur.copy("COPY person FROM STDIN") as cp:
            for t in people.values():
                cp.write_row(t)
        with cur.copy("COPY title_director FROM STDIN") as cp:
            for t in directors:
                cp.write_row(t)
        with cur.copy("COPY movie FROM STDIN") as cp:
            for t in movies:
                cp.write_row(t)
        genre_id = dict(cur.execute("SELECT genre_name, genre_id FROM genre").fetchall())
        bad_genres = {g for _, g in movie_genres} - genre_id.keys()
        if bad_genres:
            raise SystemExit(f"genres not in the vocabulary (BR-9): {bad_genres}")
        with cur.copy("COPY movie_genre FROM STDIN") as cp:
            for mid, g in movie_genres:
                cp.write_row((mid, genre_id[g]))
        log("movies, genres and IMDb tables inserted")

        # --------------------------------------------------------------
        # 3. Ratings. Pass 1 reads the users and the half-star switch off the
        #    file; pass 2 streams it straight into rating, converting the Unix
        #    time on the way (no staging table: on this disk every extra scan
        #    of 32M rows costs minutes).
        # --------------------------------------------------------------
        users, first_half = set(), None
        for line in rating_lines():
            u, _, s, ts = line.split(",")
            users.add(int(u))
            if s[-1] != "0" and (first_half is None or int(ts) < first_half):
                first_half = int(ts)
        # BR-3: the scale switch is a fact read off the data, not a guess
        switch = dt.datetime.fromtimestamp(first_half, dt.timezone.utc)
        # HALF moves first: shortening WHOLE first would briefly overlap (exclusion constraint)
        cur.execute("UPDATE rating_scale SET valid_from = %s WHERE scale_code = 'HALF'", (switch,))
        cur.execute("UPDATE rating_scale SET valid_to = %s WHERE scale_code = 'WHOLE'", (switch,))
        with cur.copy("COPY ml_user FROM STDIN") as cp:
            for u in sorted(users):
                cp.write_row((u,))
        log(f"{len(users):,} users; half-star scale in force from {switch}")

        # Drop rating's keys and index, insert, rebuild them once (§8 of 01_design.md)
        cons = cur.execute("""SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
                              WHERE conrelid = 'rating'::regclass AND contype IN ('p', 'f')
                              ORDER BY contype DESC""").fetchall()       # p before f
        idx = cur.execute("""SELECT indexname, indexdef FROM pg_indexes
                             WHERE schemaname = 'movielens' AND tablename = 'rating'
                               AND indexname <> 'pk_rating'""").fetchall()
        for name, _ in idx:
            cur.execute(f"DROP INDEX {name}")
        for name, _ in reversed(cons):
            cur.execute(f"ALTER TABLE rating DROP CONSTRAINT {name}")
        days = {}                                   # epoch day → 'YYYY-MM-DD' (10K distinct days)
        n = 0
        with cur.copy("COPY rating (user_id, movie_id, stars, rated_at) FROM STDIN") as cp:
            buf = []
            for line in rating_lines():
                u, m, s, ts = line.split(",")
                d, sec = divmod(int(ts), 86400)
                day = days.get(d) or days.setdefault(d, (EPOCH + dt.timedelta(days=d)).isoformat())
                buf.append(f"{u}\t{m}\t{s}\t{day} {sec // 3600:02}:{sec // 60 % 60:02}:{sec % 60:02}+00\n")
                if len(buf) == 200_000:
                    cp.write("".join(buf))
                    n += len(buf)
                    buf.clear()
            cp.write("".join(buf))
            n += len(buf)
        log(f"ratings copied and checked by the BR-3/BR-4 statement triggers: {n:,}")
        for name, ddl in cons:
            cur.execute(f"ALTER TABLE rating ADD CONSTRAINT {name} {ddl}")
        for _, ddl in idx:
            cur.execute(ddl)
        log("rating keys, foreign keys and index rebuilt")

        # --------------------------------------------------------------
        # 4. Tags
        # --------------------------------------------------------------
        tag_id, apps = {}, {}
        for r in ml_csv("tags.csv"):
            text = (r["tag"] or "").strip()
            key = (int(r["userId"]), int(r["movieId"]))
            if key[0] not in users:         # only with ML_SAMPLE: the user was not loaded
                continue
            if not text:
                rejected.append(("tags.csv", f"{key[0]},{key[1]},{r['timestamp']}", "BR-10: empty tag"))
                continue
            if len(text) > 300:
                rejected.append(("tags.csv", f"{key[0]},{key[1]}", "BR-10: tag longer than 300 characters"))
                continue
            tid = tag_id.setdefault(text, len(tag_id) + 1)
            k = key + (tid,)
            ts = int(r["timestamp"])
            if k in apps:           # "music" and "music " are the same tag once trimmed
                rejected.append(("tags.csv", f"{k[0]},{k[1]},{text!r}", "BR-2: duplicate after trimming (earliest kept)"))
                apps[k] = min(apps[k], ts)
            else:
                apps[k] = ts
        with cur.copy("COPY tag (tag_text) FROM STDIN") as cp:
            for text in tag_id:                 # inserted in id order → identity values match
                cp.write_row((text,))
        got = cur.execute("SELECT min(tag_id), max(tag_id) FROM tag").fetchone()
        assert got == (1, len(tag_id)), got
        with cur.copy("COPY tag_application FROM STDIN") as cp:
            for (u, m, t), ts in apps.items():
                cp.write_row((u, m, t, dt.datetime.fromtimestamp(ts, dt.timezone.utc)))
        log(f"tags: {len(tag_id):,} distinct, {len(apps):,} applications")

    log("base data committed")

    # ------------------------------------------------------------------
    # 5. Derived statistics and the data-quality log. A separate transaction:
    #    it only rebuilds derived data, so it can be re-run on its own
    #    (CALL refresh_research()) without reloading 32M rows.
    # ------------------------------------------------------------------
    with connect() as conn:
        conn.execute("SET work_mem = '256MB'")
        conn.add_notice_handler(lambda d: log(f"  {d.message_primary}"))
        conn.execute("CALL refresh_research()")
    log("refresh_research() done")

    with open(os.path.join(WORK, "rejected_rows.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["file", "row", "reason"])
        w.writerows(rejected)
    log(f"done. rejected rows: {len(rejected)} (data/work/rejected_rows.csv)")


if __name__ == "__main__":
    main()
