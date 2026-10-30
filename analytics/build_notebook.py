"""Builds movielens_kmeans.ipynb from the cells below.

Run:  .venv\\Scripts\\python analytics\\build_notebook.py
then: .venv\\Scripts\\jupyter nbconvert --to notebook --execute --inplace analytics\\movielens_kmeans.ipynb
"""
from pathlib import Path

import nbformat as nbf

HERE = Path(__file__).parent
READINGS = HERE / "readings.md"      # interpretation text, written after reading the results
cells = []


def md(text):
    cells.append(nbf.v4.new_markdown_cell(text.strip()))


def code(text):
    cells.append(nbf.v4.new_code_cell(text.strip()))


def reading(key):
    """Insert the "@@ key" section of readings.md, if it exists."""
    if not READINGS.exists():
        return
    txt = READINGS.read_text(encoding="utf-8")
    parts = {p.split("\n", 1)[0].strip(): p.split("\n", 1)[1] for p in txt.split("\n@@ ")[1:]}
    if key in parts:
        md(parts[key])


md("""
# MovieLens Analytics: How People Rate, and Who They Are

**FDS course project (MovieLens 32M).** The database holds 32,000,204 ratings and 2,000,051 tag applications
by 200,948 users on 87,585 films (1995–2023), linked to IMDb, in a BCNF schema whose triggers
enforce the rules the CSV files only imply. This notebook is a small research case study:

> 1. **How is attention distributed?** The long tail of films.
> 2. **Do the rules of the interface change behaviour?** The 2003 half-star switch as a natural experiment.
> 3. **Were old films better?** Separating quality from survivorship.
> 4. **Is popular good?** Popularity, quality, and agreement with IMDb.
> 5. **Can a recommender written in SQL beat "show everyone the hits"?**
> 6. **What kinds of users are there?** k-means on rating behaviour, and who the recommender serves.

**Workflow**

1. **SQL first.** Statistics run *inside PostgreSQL* (`07_analytics.sql`, A1–A9). Only aggregates
   leave the database: 32M rows never travel to Python.
2. **Statistical inference** on those aggregates (paired t, difference-in-differences, bootstrap).
3. **A recommender in SQL** (R1–R2): item-to-item cosine similarity from co-likes, a temporal
   train/test split, and three methods compared.
4. **Feature engineering in SQL.** `v_user_features` turns each user's ratings into one row.
5. **k-means** on standardized features; *k* chosen by elbow, silhouette and interpretability.
6. **Write back** the labels to the BCNF tables `segment` / `user_segment`, then answer S1–S2 in SQL.

*Data: MovieLens 32M (GroupLens, Harper & Konstan 2015); IMDb non-commercial datasets.*
""")

md("""
## 0. Setup

Reads use the role **`movielens_readonly`** (SELECT only). Only the write-back in §6 connects as
the owner: least privilege. `run_sql()` runs one labelled query from `07_analytics.sql`, so the
SQL on the slides and the SQL executed here are the same text.
""")

code(r'''
import os
import re
import warnings

os.environ.setdefault("LOKY_MAX_CPU_COUNT", "4")   # stops joblib probing the CPU count on Windows
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
from scipy import stats
from sklearn.cluster import KMeans
from sklearn.decomposition import PCA
from sklearn.metrics import silhouette_score
from sklearn.preprocessing import StandardScaler
from sqlalchemy import create_engine, text

warnings.filterwarnings("ignore", category=UserWarning)
pd.set_option("display.width", 160)

OPTS = {"options": "-c search_path=movielens,public -c work_mem=256MB -c timezone=UTC"}
DB = os.environ.get("MOVIELENS_DB", "movielens")       # movielens_dev = the ML_SAMPLE test database
reader = create_engine(f"postgresql+psycopg://movielens_readonly:readonly@localhost/{DB}", connect_args=OPTS)
writer = create_engine(f"postgresql+psycopg://postgres:postgres@localhost/{DB}", connect_args=OPTS)

ROOT = Path.cwd() if (Path.cwd() / "07_analytics.sql").exists() else Path.cwd().parent
SQL_FILE = ROOT / "07_analytics.sql"
FIG = ROOT / "analytics" / "figures"
FIG.mkdir(parents=True, exist_ok=True)

# A labelled query in 07_analytics.sql is a "-- A1. TITLE" header block,
# closed by a "-- ====" line, followed by one statement ending in ";".
_QUERY = re.compile(r"^-- ([ARS]\d)\. ([^\n]*)\n.*?^-- =+\n\n(.*?;)\s*$", re.M | re.S)
QUERIES = {m[1]: (m[2].strip(), m[3]) for m in _QUERY.finditer(SQL_FILE.read_text(encoding="utf-8"))}

def run_sql(label):
    title, sql = QUERIES[label]
    print(f"{label}. {title}")
    return num(query(sql))

def query(sql, **params):
    with reader.connect() as c:
        return pd.read_sql(text(sql), c, params=params)

def num(df):
    """NUMERIC columns arrive as Decimal objects: make them floats."""
    for c in df.columns:
        if df[c].dtype == object:
            try:
                df[c] = pd.to_numeric(df[c])
            except (ValueError, TypeError):
                pass
    return df

print("Queries found:", ", ".join(QUERIES))
''')

code(r'''
# Chart style: one recessive grid, thin marks, text in ink colours (never series colours).
INK, INK2, GRID, SURFACE = "#0b0b0b", "#52514e", "#e4e3df", "#fcfcfb"
BLUE, ORANGE, AQUA, YELLOW, RED, MID = "#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e34948", "#f0efec"
PALETTE = [BLUE, ORANGE, AQUA, YELLOW, RED]
plt.rcParams.update({
    "figure.facecolor": SURFACE, "axes.facecolor": SURFACE, "savefig.facecolor": SURFACE,
    "axes.edgecolor": GRID, "axes.labelcolor": INK2, "axes.titlecolor": INK,
    "axes.titleweight": "bold", "axes.titlesize": 12, "axes.titlelocation": "left",
    "xtick.color": INK2, "ytick.color": INK2, "text.color": INK,
    "axes.grid": True, "axes.axisbelow": True, "grid.color": GRID, "grid.linewidth": 0.8,
    "axes.spines.top": False, "axes.spines.right": False,
    "font.size": 10, "figure.dpi": 110,
})

def save(fig, name):
    fig.savefig(FIG / f"{name}.png", dpi=200, bbox_inches="tight")
''')

code(r'''
# What is in the database
query("""
SELECT (SELECT count(*) FROM ml_user)          AS users,
       (SELECT count(*) FROM movie)            AS films,
       (SELECT sum(n_ratings) FROM mv_movie_stats) AS ratings,
       (SELECT count(*) FROM tag_application)  AS tag_applications,
       (SELECT count(*) FROM imdb_title)       AS imdb_titles,
       (SELECT count(*) FROM title_director)   AS director_credits,
       (SELECT min(first_rated)::date FROM mv_user_stats) AS first_rating,
       (SELECT max(last_rated)::date  FROM mv_user_stats) AS last_rating
""")
''')

# ---------------------------------------------------------------------
md("""
## 1. How is attention distributed?
""")

code('a1 = run_sql("A1"); a1')

code(r'''
n = num(query("SELECT n_ratings FROM mv_movie_stats ORDER BY n_ratings")).n_ratings.to_numpy()
films = np.arange(1, len(n) + 1) / len(n)
lorenz = np.cumsum(n) / n.sum()
fig, axes = plt.subplots(1, 2, figsize=(11, 3.8))
ax = axes[0]
ax.plot(films * 100, lorenz * 100, color=BLUE, lw=2, label="Ratings")
ax.plot([0, 100], [0, 100], color=INK2, ls="--", lw=1, label="Perfect equality")
ax.fill_between(films * 100, lorenz * 100, films * 100, color=BLUE, alpha=0.08)
ax.set_xlabel("% of films (least rated first)"); ax.set_ylabel("% of all ratings")
ax.set_title(f"Lorenz curve: Gini = {a1.gini[0]:.2f}"); ax.legend(frameon=False)
ax = axes[1]
ax.loglog(np.arange(1, len(n) + 1), n[::-1], color=ORANGE, lw=2)
ax.set_xlabel("Film rank by ratings (log)"); ax.set_ylabel("Ratings (log)")
ax.set_title("The long tail")
fig.tight_layout(); save(fig, "01_long_tail"); plt.show()
''')
reading("A1")

# ---------------------------------------------------------------------
md("""
## 2. Do the rules of the interface change behaviour? The half-star switch

MovieLens added half stars in **February 2003** (the database knows the exact second: it is the
`rating_scale` boundary that trigger BR-3 enforces). Interface changes are rarely this clean, so
this is a **natural experiment**. A2 compares the distribution two years either side; A3 follows
the *same users* across the switch, and across a **placebo date** five years later with no rule
change, to separate the switch from ordinary drift (**difference-in-differences**).
""")

code('a2 = run_sql("A2"); a2')

code(r'''
fig, ax = plt.subplots(figsize=(8, 3.4))
x = np.arange(len(a2)); w = 0.4
ax.bar(x - w / 2, a2.before_pct, w, color=INK2, label="2 years before the switch")
ax.bar(x + w / 2, a2.after_pct, w, color=BLUE, label="2 years after")
ax.set_xticks(x, [f"{s:g}" for s in a2.stars]); ax.set_xlabel("Stars"); ax.set_ylabel("% of ratings")
ax.grid(axis="x", visible=False); ax.legend(frameon=False)
ax.set_title("Where the half stars came from")
save(fig, "02_half_star_distribution"); plt.show()
''')
reading("A2")

code('a3 = run_sql("A3"); a3')

code(r'''
# p-values for the paired t statistics computed in SQL, and the DiD's standard error
for r in a3.itertuples():
    p = 2 * stats.t.sf(abs(r.paired_t), r.users - 1)
    print(f"{r.label:20s} users={r.users:6,d}  change={r.within_user_change:+.4f}  t={r.paired_t:6.2f}  p={p:.1e}")
''')
reading("A3")

# ---------------------------------------------------------------------
md("""
## 3. Were old films better?

A4 compares films **between** each other by their age when rated. A5 follows the **same film**
as it ages (ratings demeaned by the film's own mean: a fixed-effects regression in one SQL
aggregate, `regr_slope`).
""")

code('a4 = run_sql("A4"); a4')
code('a5 = run_sql("A5"); a5')

code(r'''
fig, ax = plt.subplots(figsize=(8, 3.4))
ax.plot(a4.film_age_years, a4.mean_stars, color=BLUE, marker="o", lw=2)
for x_, y_, n_ in zip(a4.film_age_years, a4.mean_stars, a4.ratings):
    ax.annotate(f"{n_ / 1e6:.1f}M", (x_, y_), xytext=(0, 7), textcoords="offset points", ha="center", fontsize=8, color=INK2)
ax.set_xlabel("Film's age when rated (years)"); ax.set_ylabel("Mean stars")
ax.set_title(f"Older films score higher, but the same film drifts {a5.within_film_slope_per_year[0]:+.3f} stars a year")
save(fig, "03_film_age"); plt.show()
''')
reading("A4")

# ---------------------------------------------------------------------
md("""
## 4. Is popular good?
""")

code('a6 = run_sql("A6"); a6')
code('a7 = run_sql("A7"); a7')

code(r'''
both = num(query("""SELECT bayes_stars, imdb_rating, n_ratings FROM v_movie
                    WHERE n_ratings >= 100 AND imdb_votes >= 1000 AND type_code = 'movie'"""))
fig, axes = plt.subplots(1, 2, figsize=(11, 3.8))
ax = axes[0]
ax.bar(a6.pop_decile, a6.mean_of_film_means, color=BLUE)
ax.set_ylim(a6.mean_of_film_means.min() - 0.3, a6.mean_of_film_means.max() + 0.15)
ax.set_xticks(a6.pop_decile); ax.set_xlabel("Popularity decile (1 = least rated)"); ax.set_ylabel("Mean of film means")
ax.grid(axis="x", visible=False); ax.set_title("More-rated films score higher")
ax = axes[1]
ax.scatter(both.imdb_rating, both.bayes_stars, s=4, alpha=0.25, color=BLUE, edgecolor="none")
ax.set_xlabel("IMDb rating (1-10)"); ax.set_ylabel("MovieLens Bayesian average (stars)")
ax.set_title(f"MovieLens vs IMDb: Spearman {a7.spearman[0]:.2f} ({a7.films[0]:,} films)")
fig.tight_layout(); save(fig, "04_popularity_imdb"); plt.show()
''')
reading("A6")

md("""
### Genres and experience
""")

code('a8 = run_sql("A8"); a8')

code(r'''
fig, ax = plt.subplots(figsize=(7.6, 4.4))
d = a8[a8.genre_name != "IMAX"]
ax.scatter(d.mean_stars, d.sd_stars, s=np.sqrt(d.ratings) / 4, color=BLUE, alpha=0.6, edgecolor=SURFACE)
for r in d.itertuples():
    ax.annotate(r.genre_name, (r.mean_stars, r.sd_stars), xytext=(4, 3), textcoords="offset points", fontsize=8)
ax.set_xlabel("Mean stars"); ax.set_ylabel("Standard deviation (how divided)")
ax.set_title("Genres: quality and division (bubble = ratings)")
save(fig, "05_genres"); plt.show()
''')
reading("A8")

code('a9 = run_sql("A9"); a9')
reading("A9")

# ---------------------------------------------------------------------
md("""
## 5. Can a recommender written in SQL beat "show everyone the hits"?

`build_recommender()` in `07_analytics.sql` does everything in the database:

- **Temporal holdout.** Train on ratings before 2021-01-01, test on the 2021–2023 ratings. A random
  split would leak the future into the past.
- **Item-to-item similarity.** For the 2,000 most-liked films, cosine similarity of *co-likes*
  (≥ 4 stars): `co(i, j) / √(n_i · n_j)`, a self-join of the ratings table, keeping each film's top 50 neighbours.
- **Three methods**, each recommending 10 unseen films to each test user: **POPULAR** (most-liked),
  **TOP_RATED** (best Bayesian average), **ITEM_KNN** (sum of similarities to the user's 50 latest likes).
""")

code('r1 = run_sql("R1"); r1')

code(r'''
# Paired bootstrap of the hit-rate difference ITEM_KNN − POPULAR (same users in both)
hits = num(query("""
WITH test_likes AS (
    SELECT r.user_id, r.movie_id FROM rating r JOIN rec_test_user USING (user_id) JOIN rec_item USING (movie_id)
    WHERE r.rated_at >= '2021-01-01' AND r.stars >= 4)
SELECT l.user_id, l.method, (count(t.movie_id) > 0)::int AS hit
FROM rec_list l LEFT JOIN test_likes t ON t.user_id = l.user_id AND t.movie_id = l.movie_id
GROUP BY l.user_id, l.method"""))
h = hits.pivot(index="user_id", columns="method", values="hit").dropna()
diff = (h.ITEM_KNN - h.POPULAR).to_numpy()
rng = np.random.default_rng(42)
boot = np.array([rng.choice(diff, len(diff)).mean() for _ in range(5000)])
lo, hi = np.percentile(boot, [2.5, 97.5])
print(f"ITEM_KNN − POPULAR hit rate: {diff.mean() * 100:+.1f} points, 95% CI [{lo * 100:+.1f}, {hi * 100:+.1f}], users = {len(diff):,}")
''')

code(r'''
fig, axes = plt.subplots(1, 2, figsize=(11, 3.4))
order = ["POPULAR", "TOP_RATED", "ITEM_KNN"]
d = r1.set_index("method").loc[order]
cols = [INK2, YELLOW, BLUE]
axes[0].bar(order, d.hit_rate_pct, color=cols); axes[0].set_ylabel("Hit rate @10 (%)")
axes[0].set_title("Users with ≥ 1 future like in their 10")
axes[1].bar(order, d.films_ever_recommended, color=cols); axes[1].set_ylabel("Distinct films ever recommended")
axes[1].set_title("Catalogue coverage")
for ax in axes: ax.grid(axis="x", visible=False)
fig.tight_layout(); save(fig, "06_recommender"); plt.show()
''')
reading("R1")

code('r2 = run_sql("R2"); r2')
reading("R2")

# ---------------------------------------------------------------------
md("""
## 6. What kinds of users are there? (k-means)

`v_user_features` gives one row per user (all 200,948): **activity** (ln ratings), **generosity**
(mean stars), **spread** (SD of stars), **mainstream** (average ln-popularity of the films they rate),
**classic share** (films ≥ 20 years old when rated), **conformity** (correlation of their stars with
the crowd's), **half-star share**.

### 6.1 Features
""")

code(r'''
FEATURES = ["ln_ratings", "mean_stars", "sd_stars", "mainstream", "classic_share", "conformity", "half_share"]
usr = num(query("SELECT * FROM v_user_features"))
print(len(usr), "users")
usr[FEATURES].describe().round(3)
''')

code(r'''
corr = usr[FEATURES].corr()
fig, ax = plt.subplots(figsize=(5.6, 4.6))
im = ax.imshow(corr, cmap="RdBu_r", vmin=-1, vmax=1)
k_ = len(FEATURES)
ax.set_xticks(range(k_), FEATURES, rotation=40, ha="right"); ax.set_yticks(range(k_), FEATURES)
for i in range(k_):
    for j in range(k_):
        ax.text(j, i, f"{corr.iloc[i, j]:.2f}", ha="center", va="center", fontsize=8,
                color="white" if abs(corr.iloc[i, j]) > 0.6 else INK)
ax.grid(False); ax.set_title("Feature correlations")
fig.colorbar(im, ax=ax, shrink=0.8); save(fig, "07_feature_correlation"); plt.show()
''')
reading("6.1")

md("""
### 6.2 Choosing k
Silhouette is computed on a fixed random sample of 20,000 users (it is O(n²)).
""")

code(r'''
X = StandardScaler().fit_transform(usr[FEATURES])
rng = np.random.default_rng(42)
sample = rng.choice(len(X), min(20_000, len(X)), replace=False)
rows = []
for k in range(2, 9):
    km = KMeans(n_clusters=k, n_init=10, random_state=42).fit(X)
    rows.append((k, km.inertia_, silhouette_score(X[sample], km.labels_[sample])))
kres = pd.DataFrame(rows, columns=["k", "inertia", "silhouette"])
kres.round(3)
''')
reading("6.2")

code(r'''
K = 4
km = KMeans(n_clusters=K, n_init=20, random_state=42).fit(X)
usr["cluster"] = km.labels_
usr["distance"] = np.linalg.norm(X - km.cluster_centers_[km.labels_], axis=1)
centroids = usr.groupby("cluster")[FEATURES].mean()
centroids.assign(users=usr.groupby("cluster").size()).round(3)
''')

code(r'''
# Name clusters by rules on the centroids, not by k-means' arbitrary label numbers
names, left = {}, set(centroids.index)
def take(col, how, name):
    sub = centroids.loc[sorted(left), col]
    c = sub.idxmax() if how == "max" else sub.idxmin()
    names[c] = name; left.discard(c)
take("ln_ratings", "max", "Cinephiles")
take("half_share", "min", "1990s Pioneers")
take("mean_stars", "max", "Easy Pleasers")
take("mean_stars", "min", "Tough Critics")
usr["segment"] = usr["cluster"].map(names)

DESC = {
    "Cinephiles": "The heaviest raters: hundreds of films each, the least mainstream taste, the most in step with the crowd.",
    "1990s Pioneers": "Almost never use half stars: nine in ten joined before the 2003 switch, when half stars did not exist yet.",
    "Easy Pleasers": "The most generous and most consistent raters: high stars with little spread.",
    "Tough Critics": "Low average stars and the widest spread: they use the bottom of the scale.",
}
profile = usr.groupby("segment")[FEATURES].mean().round(3).assign(users=usr.groupby("segment").size()).loc[list(DESC)]
profile
''')

code(r'''
fig, axes = plt.subplots(1, 2, figsize=(11, 3.8))
ax = axes[0]
ax.plot(kres.k, kres.inertia, color=BLUE, marker="o", lw=2); ax.set_xlabel("k"); ax.set_ylabel("Inertia (within-cluster SS)")
ax2 = ax.twinx(); ax2.plot(kres.k, kres.silhouette, color=ORANGE, marker="s", lw=2)
ax2.set_ylabel("Silhouette"); ax2.grid(False); ax2.spines["right"].set_visible(True)
ax.axvline(K, color=INK2, ls="--", lw=1); ax.set_title(f"Choosing k (k = {K})")
pca = PCA(2).fit(X); P = pca.transform(X)
ax = axes[1]
for i, seg in enumerate(DESC):
    m = (usr.segment == seg).values & np.isin(np.arange(len(X)), sample)
    ax.scatter(P[m, 0], P[m, 1], s=4, color=PALETTE[i], label=seg, edgecolor="none", alpha=0.5)
ax.set_xlabel(f"PC1 ({pca.explained_variance_ratio_[0]:.0%} of variance)")
ax.set_ylabel(f"PC2 ({pca.explained_variance_ratio_[1]:.0%})")
ax.legend(frameon=False, fontsize=8, markerscale=3); ax.set_title("Four kinds of user (PCA view, 20K sample)")
fig.tight_layout(); save(fig, "08_segments"); plt.show()
''')

code(r'''
z = pd.DataFrame(X, columns=FEATURES).assign(segment=usr.segment.values).groupby("segment").mean().loc[list(DESC)]
fig, ax = plt.subplots(figsize=(7.6, 2.8))
im = ax.imshow(z, cmap="RdBu_r", vmin=-2, vmax=2, aspect="auto")
ax.set_xticks(range(len(FEATURES)), FEATURES, rotation=25, ha="right"); ax.set_yticks(range(K), z.index)
for i in range(K):
    for j in range(len(FEATURES)):
        ax.text(j, i, f"{z.iloc[i, j]:+.1f}", ha="center", va="center", fontsize=8, color="white" if abs(z.iloc[i, j]) > 1.2 else INK)
ax.grid(False); ax.set_title("Segment fingerprints (centroids in SD units)")
fig.colorbar(im, ax=ax, shrink=0.8); save(fig, "09_fingerprints"); plt.show()
''')
reading("6.3")

md("""
## 7. Write the segments back to the database

The labels go into `segment` and `user_segment`, so SQL can use them. This is the only step that
connects as the owner, and it runs in one transaction: a failure leaves the old segments in place.
""")

code(r'''
with writer.begin() as c:
    c.execute(text("DELETE FROM segment"))                # cascades to user_segment
    ids = {seg: c.execute(text("INSERT INTO segment (segment_name, description) VALUES (:n, :d) RETURNING segment_id"),
                          {"n": seg, "d": d}).scalar_one()
           for seg, d in DESC.items()}
    raw = c.connection.driver_connection                  # psycopg COPY: 200K rows in one round trip
    with raw.cursor() as cur, cur.copy("COPY user_segment (user_id, segment_id, distance) FROM STDIN") as cp:
        for r in usr.itertuples():
            cp.write_row((int(r.user_id), ids[r.segment], round(float(r.distance), 3)))
query("SELECT * FROM v_segment_profile ORDER BY users DESC")
''')

md("""
**Check: when did each segment rate?** The features say nothing about dates, yet one segment
avoids half stars. If it is the users of the WHOLE scale (BR-3), they rated before 2003.
""")

code(r'''
query("""
SELECT s.segment_name, count(*) AS users,
       round(100.0 * avg((u.first_rated < half_star_switch())::int), 1) AS joined_before_switch_pct,
       percentile_disc(0.5) WITHIN GROUP (ORDER BY extract(year FROM u.first_rated)) AS median_first_year,
       round(100.0 * avg((u.last_rated >= '2021-01-01')::int), 1) AS active_2021_pct
FROM user_segment us JOIN segment s USING (segment_id) JOIN mv_user_stats u USING (user_id)
GROUP BY s.segment_name ORDER BY median_first_year
""")
''')
reading("6.4")

md("""
## 8. Using the segments in SQL

### S1. What does each segment watch?
""")

code(r'''
s1 = run_sql("S1")
lift = s1.pivot(index="genre_name", columns="segment_name", values="lift")[list(DESC)]
lift = lift.loc[lift.std(axis=1).sort_values(ascending=False).index]
fig, ax = plt.subplots(figsize=(6.4, 5.6))
im = ax.imshow(np.log2(lift), cmap="RdBu_r", vmin=-1, vmax=1, aspect="auto")
ax.set_xticks(range(K), lift.columns, rotation=20, ha="right"); ax.set_yticks(range(len(lift)), lift.index)
for i in range(len(lift)):
    for j in range(K):
        ax.text(j, i, f"{lift.iloc[i, j]:.2f}", ha="center", va="center", fontsize=7, color=INK)
ax.grid(False); ax.set_title("Genre lift by segment (1 = average)")
save(fig, "10_genre_lift"); plt.show()
''')
reading("S1")

md("""
### S2. Which segment is the recommender good for?
""")

code('s2 = run_sql("S2"); s2')

code(r'''
d = s2.set_index("segment_name").reindex([s for s in DESC if s in set(s2.segment_name)])
fig, ax = plt.subplots(figsize=(7.2, 3.0))
y = np.arange(len(d))
ax.barh(y - 0.2, d.popular_hit_rate_pct, 0.4, color=INK2, label="POPULAR")
ax.barh(y + 0.2, d.knn_hit_rate_pct, 0.4, color=BLUE, label="ITEM_KNN")
ax.set_yticks(y, d.index); ax.invert_yaxis(); ax.set_xlabel("Hit rate @10 (%)")
ax.grid(axis="y", visible=False); ax.legend(frameon=False, fontsize=8)
ax.set_title("Who the recommender helps")
save(fig, "11_recommender_by_segment"); plt.show()
''')
reading("S2")

reading("Conclusions")

nb = nbf.v4.new_notebook()
nb["cells"] = cells
# Kernel = MovieLens/.venv (registered once with: .venv\Scripts\python -m ipykernel install --user --name movielens)
nb["metadata"]["kernelspec"] = {"name": "movielens", "display_name": "MovieLens (.venv)", "language": "python"}
out = HERE / "movielens_kmeans.ipynb"
nbf.write(nb, out)
print("wrote", out)
