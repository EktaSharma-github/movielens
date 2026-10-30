"""Download the raw data into data/raw/ (stdlib only; files already present are skipped).

  MovieLens 32M  https://files.grouplens.org/datasets/movielens/ml-32m.zip  (~240 MB, unzipped ~960 MB)
  IMDb           https://datasets.imdbws.com/  title.basics, title.ratings, title.crew, name.basics (~630 MB)

The MovieLens files are verified against the MD5 checksums GroupLens ships in the zip.
IMDb data is for personal, non-commercial use (https://developer.imdb.com/non-commercial-datasets/).

Usage:  .venv\\Scripts\\python data\\fetch.py
"""
import hashlib
import os
import shutil
import urllib.request
import zipfile

RAW = os.path.join(os.path.dirname(os.path.abspath(__file__)), "raw")
ML_URL = "https://files.grouplens.org/datasets/movielens/ml-32m.zip"
IMDB_URL = "https://datasets.imdbws.com/{}.tsv.gz"
IMDB_FILES = ["title.basics", "title.ratings", "title.crew", "name.basics"]


def download(url, path):
    if os.path.exists(path):
        print(f"have  {os.path.relpath(path, RAW)}")
        return
    print(f"get   {url}", flush=True)
    tmp = path + ".part"
    with urllib.request.urlopen(url, timeout=120) as r, open(tmp, "wb") as f:
        shutil.copyfileobj(r, f, 8 << 20)
    os.replace(tmp, path)


def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        while chunk := f.read(8 << 20):
            h.update(chunk)
    return h.hexdigest()


def main():
    os.makedirs(os.path.join(RAW, "imdb"), exist_ok=True)

    z = os.path.join(RAW, "ml-32m.zip")
    download(ML_URL, z)
    if not os.path.exists(os.path.join(RAW, "ml-32m", "ratings.csv")):
        with zipfile.ZipFile(z) as zf:
            zf.extractall(RAW)
    with open(os.path.join(RAW, "ml-32m", "checksums.txt")) as f:
        for line in f:
            want, name = line.split()
            got = md5(os.path.join(RAW, "ml-32m", name))
            if got != want:
                raise SystemExit(f"MD5 mismatch for {name}: {got} != {want}")
    print("MovieLens checksums OK")

    for name in IMDB_FILES:
        download(IMDB_URL.format(name), os.path.join(RAW, "imdb", f"{name}.tsv.gz"))


if __name__ == "__main__":
    main()
