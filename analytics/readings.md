Interpretation text for movielens_kmeans.ipynb. Each "@@ key" section is inserted after the
cell it describes by build_notebook.py. Numbers are from the full MovieLens 32M load.

@@ A1
**Reading.** Attention is extremely unequal. The top 1% of films (about 840) collect **54.8%**
of all 32 million ratings, and the top 10% collect **95.7%**. Most of the catalogue is barely
seen: **62.1%** of rated films have fewer than 10 ratings. The Gini coefficient is **0.952**.
Income inequality in the most unequal countries is around 0.6.

*Why this matters for the database:* any per-film average is unreliable for most films. That is
why `v_movie` ranks by a Bayesian average (shrunk towards the global mean with a prior of 50
ratings) and not by the raw mean. It is also why `08_optimizer.sql` finds PostgreSQL's
sample-based estimate of distinct films about 11× too low: a 30,000-row sample rarely contains
the tail.

@@ A2
**Reading.** Before February 2003 the scale had five values. Afterwards half stars took
**40.7%** of all ratings (0.5 + 1.5 + 2.5 + 3.5 + 4.5). Every whole value gave up share: 3, 4 and 5
stars each lost 10–11 points, and 5 stars more than halved (20.1% → 9.1%). A "very good" film that
used to be rounded to 4 or 5 could now get 4.5, and the most-used new value is 3.5 (17.4%).

*Caveat:* the before and after columns contain different users and different films, so this is
a comparison of two populations, not yet an effect. A3 follows the same users across the switch.

@@ A3
**Reading.** A3 follows **2,643 users** who rated at least 20 films in each of the two years
around the switch. Their own mean rose by **+0.046 stars** (paired t = 7.0). Users followed across
an arbitrary date five years later (the placebo) also drifted, by +0.026 stars (t = 4.2). The
difference-in-differences, the part we can attribute to the switch itself, is **+0.020 stars**.
That is statistically clear and practically tiny.

Half stars changed the *shape* of ratings a great deal (41% of ratings after the switch use
them) but barely moved the *level*. Users split their old whole stars into halves in both
directions. The placebo shows why a natural experiment needs a control: without it, we would
have reported more than twice the true effect.

@@ A4
**Reading.** Ratings rise with a film's age: films rated in their release year average
**3.42 stars**, and films more than 40 years old **3.80**. Did the cinema of the past simply
make better films?

A5 answers no. Following the *same* film as it ages (2,126 films released 1996–2012, each with
at least 1,000 ratings, ages 0–10), the rating **falls** by **0.0185 stars per year**, about
0.2 stars over a decade. The rising age curve is therefore **survivorship**. Nobody in 2020
watches the forgotten films of 1950; they watch *Casablanca*. Old films in the data are a
selected sample of the best. Their early audience is also selected: fans see a film first and
rate it highest.

@@ A6
**Reading.** Popular films are rated higher, though not by much. The least-rated tenth of films
average **2.99** and the most-rated tenth **3.44**; the correlation between log popularity and
mean rating is **0.26**. Part of this is quality (good films spread) and part is selection:
people choose what to watch, and they choose things they expect to like.

MovieLens users and IMDb voters agree closely on which films are good: across 11,535 films with
enough votes on both sites, **Pearson r = 0.92** and Spearman ρ = 0.93. The disagreements in
Q5 (`05_queries.sql`) are telling. *Home Alone*, *Titanic* and *Dumb & Dumber* sit far higher on
IMDb, while puzzle films like *Primer* and *Coherence* sit higher on MovieLens. MovieLens users are
the more "cinephile" crowd.

@@ A8
**Reading.** **Film-Noir** is the best-rated genre (3.92) and the least divisive (SD 0.91).
**Horror** is the worst-rated (3.31) and the most divisive (SD 1.13): 9.8% of horror ratings are
2 stars or fewer, against 2.6% for noir.

This is again selection, not a verdict on genres. Noir has a small, self-selected audience
(305K ratings); comedy and drama are watched by everyone, including people who do not like them.

@@ A9
**Reading.** Among users with at least 500 ratings, the first 20 ratings sit **0.30 stars above
the user's own average**, and ratings after the 500th sit **0.08 below** it. One person's ratings
drift downward with experience.

There are two explanations. First, MovieLens asks new users to rate films they already know,
so the first ratings are of remembered favourites. Second, after hundreds of films the easy
wins are used up and people try riskier choices. Either way, *when* a rating was given matters,
which is one reason the recommender is evaluated on a time split and not a random one.

@@ R1
**Reading.** On **459 test users**, their ratings after 1 January 2021 kept hidden, the
item-to-item recommender written entirely in SQL beats "show everyone the hits":

| | Hit rate @10 | Precision @10 | Films ever recommended |
|---|---|---|---|
| **ITEM_KNN** | **69.9%** | **17.4%** | **407** |
| POPULAR | 52.1% | 11.2% | 144 |
| TOP_RATED | 43.1% | 7.1% | 62 |

The paired bootstrap puts the improvement at **+17.9 points (95% CI +13.1 to +22.9)**, so it is
not luck. kNN is also **3× more diverse**: it recommends from 407 different films, against 144.
TOP_RATED is the weakest because acclaimed films are the ones heavy users have already seen.

The DBMS concepts at work: a self-join for co-likes (bounded by sampling users and capping each
at 100 likes, because k likes produce k² pairs), window functions for top-N per item and per
user, `NOT EXISTS` to exclude films already seen, and a stored procedure that rebuilds the whole
model in one transaction.

@@ R2
**Reading.** The similarity graph knows nothing about genres, directors or plots. It is built
only from "people who liked A also liked B", yet the neighbourhoods make sense:

- *The Matrix* → *Fight Club*, the *Lord of the Rings* trilogy, *The Empire Strikes Back* (late-90s/00s canon).
- *Toy Story* → *Toy Story 2*, *The Lion King*, *Aladdin* (family animation).
- *Pride & Prejudice* (2005) → *The Notebook*, *Love Actually*, *Atonement*, and the 1995 BBC *Pride and Prejudice*.

The cosine values for *Pride & Prejudice* are lower (≈ 0.2 against ≈ 0.5 for *The Matrix*)
because its audience is smaller and more spread out. Collaborative filtering has the most
evidence where there is the most attention, which is the long tail of A1 again.

@@ 6.1
**Reading.** Each of the 200,948 users becomes one row of 7 features, computed by a single SQL
view. The median user has about 73 ratings (e^4.29) and an average of 3.73 stars. The features
are on very different scales (log counts, stars, shares, correlations), so they are
standardized before k-means. Otherwise the feature with the largest variance would decide the
clusters alone.

@@ 6.2
**Reading.** The silhouette score peaks at **k = 4 (0.181)**, and the inertia curve bends there.
The silhouette value is low in absolute terms. Users form a continuum, not four separate groups,
so the segments are a useful *summary* of behaviour, not natural kinds. We chose k = 4 for the
silhouette peak and because all four clusters can be described in plain words.

@@ 6.3
**Reading.** The four fingerprints:

- **Cinephiles** (42,832): by far the heaviest raters (+1.4 SD; about 466 ratings each), the least mainstream films, and the most agreement with the crowd's verdict (they know which films are "good").
- **1990s Pioneers** (61,214): almost never use half stars (1.6%) and rate few old films. The features contain no dates; §7 checks what this cluster really is.
- **Easy Pleasers** (63,425): the highest average (4.10 stars) with the smallest spread: they like nearly everything they rate.
- **Tough Critics** (33,477): the lowest average (3.27) and the widest spread (SD 1.24): the only group that really uses the bottom of the scale.

@@ 6.4
**Reading.** **91% of the "1990s Pioneers" started rating before the 2003 switch** (median first
year 1997), and only 0.4% were still active in 2021. Every other segment's median start is
2010 or later. k-means received no dates and no knowledge of the scale change, yet it
rediscovered business rule **BR-3**: these are the users of the WHOLE scale. Their low
"classic share" fits too: in 1997, a film had to predate 1977 to count as 20 years old.

This is a lesson about data more than about users. A behavioural segment can be an artefact of
the system's history, and the schema's `rating_scale` table is what lets us explain it.

@@ S1
**Reading.** Genre lift = a segment's share of ratings in a genre ÷ everyone's share (1.00 = average).

- **Cinephiles** over-index on the tail genres: Documentary (1.30), Horror (1.15), Film-Noir.
- **1990s Pioneers** watched the 1990s catalogue: Western (1.32), Romance (1.24), Musical (1.20); almost no Documentary (0.44) or Animation (0.77), which were rare then.
- **Easy Pleasers** lean towards blockbusters: War, Sci-Fi, Adventure, Crime, Animation (1.12–1.15), and away from Horror and Documentary.
- **Tough Critics** over-index on family and franchise films: Animation (1.17), Fantasy, Children, Adventure. Perhaps films they were taken to, not films they chose.

@@ S2
**Reading.** The recommender beats POPULAR in every segment it can be tested on, and most where
POPULAR is weakest. For Tough Critics it more than doubles the hit rate (61.9% against 28.6%),
although that group has only 21 test users.

The bigger lesson is who is *in* the test. Cinephiles are 21% of users but **75% of test users**
(345 of 459), and the 1990s Pioneers are absent entirely: the temporal split requires activity
after 2021. Offline evaluation measures the recommender mainly for heavy users. A product team
reading only R1 would not know that.

@@ Conclusions
## Conclusions

| Question | Answer |
|---|---|
| How is attention distributed? | Extremely unequally: the top 1% of films get 55% of ratings (Gini 0.95). |
| Did half stars change behaviour? | They changed the shape (41% half stars), but the level moved only +0.02 stars after the placebo control. |
| Were old films better? | No. The same film *loses* 0.2 stars per decade; the old-film premium is survivorship. |
| Is popular good? | Weakly (r = 0.26). MovieLens and IMDb agree closely (r = 0.92). |
| Can SQL alone recommend? | Yes: item-kNN in SQL reaches a 70% hit rate against 52% for the hits (+18 points, CI 13–23). |
| What kinds of users are there? | Four segments; one is the 1990s whole-star era, rediscovered without dates. |

**Why this needed a DBMS.** Every number above is an aggregate over 32 million rows computed
*inside* PostgreSQL; Python only received the summaries. The schema did more than store data:

- the `rating_scale` table and BR-3 trigger turned "the interface changed" into a fact we could query, and explained the k-means result;
- `data_issue` kept suspicious rows with their reason instead of silently deleting them;
- the materialized views made per-film statistics instant, and are also why exact V(A, r) costs nothing in `08_optimizer.sql`;
- the optimizer study showed that a plan is only as good as the statistics and cost settings behind it.

**Limits.** MovieLens users are volunteers, not a random sample of viewers. Time effects mix
with changes in who uses the site. The recommender test covers mostly heavy users.
