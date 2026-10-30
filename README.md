# MovieLens 32M — Ratings, Bias & Recommendation Research Database

A PostgreSQL database of the MovieLens 32M dataset (32,000,204 ratings and 2,000,051 tag applications by 200,948 users on 87,585 films, 1995–2023), linked to IMDb's public title, rating and director data and normalized to BCNF. Triggers enforce the rules the CSV files only imply (no half stars before 2003, at least 20 ratings per user), and suspicious but real records are logged instead of dropped. On top: a small research case study on how people rate, written in SQL, an item-to-item recommender built and evaluated in SQL, k-means segmentation of users, and a query-optimization study on 32 million rows.

FDS (DBMS) course project, PGDBA, IIM Calcutta.

## What's inside

| File | Contents |
|---|---|
| [01_design.md](01_design.md) | Business rules, what the real data taught us, EER model, ER → relational mapping, normalization to BCNF |
| [SCHEMA.md](SCHEMA.md) | **Schema and data dictionary**: ER diagram, every table with its columns, types, keys, constraints, row counts and example values, and how the source files map to tables |
| [data/fetch.py](data/fetch.py) | Downloads MovieLens 32M (MD5-verified) and four IMDb files |
| [02_ddl.sql](02_ddl.sql) | 16 tables: keys, CHECKs, a GiST exclusion constraint on the rating-scale periods, generated columns, reference data |
| [03_logic.sql](03_logic.sql) | Statement-level triggers with transition tables (BR-3, BR-4 as an emulated ASSERTION), materialized views, `refresh_research()`, read-only role |
| [04_load.py](04_load.py) | Title/year/genre parsing, IMDb streaming join, 32M ratings streamed by COPY with keys rebuilt afterwards; base data in one transaction, research layer in a second |
| [05_queries.sql](05_queries.sql) | Five advanced queries: window functions, relational division, recursive CTE (breadth-first search), LATERAL, INTERSECT/EXCEPT |
| [06_demo.sql](06_demo.sql) | Rollback-only live demo: constraints and triggers firing, a materialized view going stale, indexing with EXPLAIN, roles |
| [07_analytics.sql](07_analytics.sql) | SQL statistics (A1–A9), the recommender (R1–R2), the k-means feature view, segment tables, segment queries (S1–S2) |
| [08_optimizer.sql](08_optimizer.sql) | Catalog statistics, selectivity and join-size estimation by hand vs the optimizer, join order, access paths, BRIN |
| [analytics/](analytics/) | Notebook (and HTML export), its builder, the written readings, and figures |
| [results/](results/) | psql output of 05, 06 and 08 on the full 32M-row database (the errors in 06 are the rules firing) |

## Headline results

- **Long tail:** the top 1% of films get 55% of all ratings (Gini 0.95).
- **Half stars (2003):** 41% of ratings moved to half stars, but the same users' average rose only +0.02 stars after a placebo control (difference-in-differences).
- **Old films are not better:** the same film loses 0.2 stars per decade; the old-film premium is survivorship.
- **Recommender in pure SQL:** item-kNN hit rate @10 is 69.9% against 52.1% for "most popular" (+17.9 points, bootstrap 95% CI 13.1–22.9).
- **k-means rediscovered a business rule:** one of four user segments almost never uses half stars, and 91% of its users joined before half stars existed.
- **Optimizer:** ANALYZE's sample underestimates distinct films 11×; extended statistics turn a 3.3-million-row misestimate into 1; the default join plan was the slowest until the cost settings matched the machine.

Details in [01_design.md §6.4](01_design.md) and the notebook.

## Run it

Needs PostgreSQL 15+ (built on 18), Python 3.12, about 6 GB of free disk. From this folder, in PowerShell:

```powershell
python -m venv .venv
.venv\Scripts\pip install -r requirements.txt
.venv\Scripts\python -m ipykernel install --user --name movielens --display-name "MovieLens (.venv)"
.\run_all.ps1                     # downloads the data (first run only), builds and loads
.venv\Scripts\python analytics\build_notebook.py
.venv\Scripts\jupyter nbconvert --to notebook --execute --inplace analytics\movielens_kmeans.ipynb
```

`.\run_all.ps1 -SkipFetch` rebuilds from the files already in `data\raw`. Segments are empty after a rebuild until the notebook runs again.

## Data and licences

- **MovieLens 32M**, GroupLens Research, University of Minnesota. F. Maxwell Harper and Joseph A. Konstan. 2015. *The MovieLens Datasets: History and Context.* ACM TiiS 5(4): 19. https://doi.org/10.1145/2827872. Research use; no endorsement by the University of Minnesota or GroupLens is implied.
- **IMDb non-commercial datasets** (https://datasets.imdbws.com/), for personal and non-commercial use. Information courtesy of IMDb (https://www.imdb.com), used with permission.

Raw files are not in the repository (`data/raw/` is git-ignored); `data/fetch.py` downloads them.
