#!/usr/bin/env python3
"""Builds Lumen/Resources/AnimeIndex.json: rating and anime genres by TVDB / TMDB / IMDb id.

Sources: Fribb/anime-lists (ids) and manami-project/anime-offline-database (tags, and the median
of the sites' scores; ODbL 1.0). With MAL_CLIENT_ID set (a free client id from
myanimelist.net/apiconfig), ratings are MyAnimeList's own, from its official API.

Also writes AnimeNames.json next to it: other Latin / Arabic titles of each anime, for search.

Usage: build_anime_index.py <anime-list-full.json> <anime-offline-database-minified.json> <out.json>
"""
import json
import os
import re
import sys
import unicodedata
import urllib.request

# Tags of the database → the genre shown in the app.
TAGS = {
    "isekai": "إيسيكاي", "shounen": "شونين", "seinen": "سينين", "shoujo": "شوجو", "josei": "جوسي",
    "mecha": "ميكا", "slice of life": "شريحة من الحياة", "harem": "حريم", "reverse harem": "حريم عكسي",
    "supernatural": "خوارق", "psychological": "نفسي", "school life": "مدرسي", "super power": "قوى خارقة",
    "military": "عسكري", "samurai": "ساموراي", "vampire": "مصاصو دماء", "vampires": "مصاصو دماء",
    "time travel": "سفر عبر الزمن", "space": "فضاء", "idol": "آيدول", "parody": "محاكاة ساخرة",
    "magical girl": "فتيات ساحرات", "demons": "شياطين", "martial arts": "فنون قتالية",
    "iyashikei": "هادئ ومريح", "survival": "بقاء", "cyberpunk": "سايبربانك",
    "post-apocalyptic": "ما بعد الكارثة", "video games": "ألعاب فيديو", "reincarnation": "تناسخ",
}


def mal_scores(client_id):
    scores, url = {}, ("https://api.myanimelist.net/v2/anime/ranking"
                       "?ranking_type=all&limit=500&fields=mean&nsfw=true")
    while url:
        request = urllib.request.Request(url, headers={"X-MAL-CLIENT-ID": client_id})
        with urllib.request.urlopen(request, timeout=60) as response:
            page = json.load(response)
        for row in page["data"]:
            if row["node"].get("mean"):
                scores[row["node"]["id"]] = row["node"]["mean"]
        url = page.get("paging", {}).get("next")
    return scores


def main():
    ids = json.load(open(sys.argv[1], encoding="utf-8"))
    database = json.load(open(sys.argv[2], encoding="utf-8"))["data"]
    by_mal = {}
    for anime in database:
        for source in anime["sources"]:
            if source.startswith("https://myanimelist.net/anime/"):
                by_mal[int(source.rsplit("/", 1)[1])] = anime
    client_id = os.environ.get("MAL_CLIENT_ID")
    official = mal_scores(client_id) if client_id else None

    shows = {"tvdb": {}, "tmdb": {}, "imdb": {}}
    for row in ids:
        if not row.get("mal_id"):
            continue
        tmdb = row.get("themoviedb_id")
        tmdb = tmdb.get("tv") if isinstance(tmdb, dict) else tmdb
        keys = {"tvdb": row.get("tvdb_id"), "tmdb": tmdb, "imdb": row.get("imdb_id")}
        for kind, values in keys.items():
            for value in values if isinstance(values, list) else [values]:
                if value:
                    shows[kind].setdefault(str(value), []).append(row)

    def score(mal):
        if official is not None:
            return official.get(mal)
        anime = by_mal.get(mal) or {}
        values = anime.get("score") or {}
        # One site's score only (all the averages are equal), or not aired yet: not a rating.
        if anime.get("status") == "UPCOMING" or len(set(values.values())) < 2:
            return None
        return values["median"]

    names = sorted(set(TAGS.values()))
    number = {name: i for i, name in enumerate(names)}

    def entry(rows):
        # The first season's series first: that's what sites rate a show by.
        def order(row):
            season = row.get("season") or {}
            number_ = season.get("tvdb", season.get("tmdb"))
            return (row.get("type") != "TV", number_ in (0, None), number_ or 0, row["mal_id"])
        rows = sorted(rows, key=order)
        # Genres of the series only, unless there's none (movies and specials add odd ones).
        series = [r for r in rows if r.get("type") == "TV"] or rows
        tags = {number[TAGS[t]] for r in series for t in (by_mal.get(r["mal_id"]) or {}).get("tags", []) if t in TAGS}
        value = next((v for v in (score(r["mal_id"]) for r in series) if v), None)
        return [round(value, 2) if value else 0, sorted(tags)]

    out = {"official": official is not None, "genres": names}
    for kind, table in shows.items():
        out[kind] = {key: entry(rows) for key, rows in sorted(table.items())}
    with open(sys.argv[3], "w", encoding="utf-8") as file:
        json.dump(out, file, ensure_ascii=False, separators=(",", ":"))
    print({k: len(v) for k, v in out.items() if isinstance(v, dict)}, len(names), "genres")
    write_names(ids, by_mal, os.path.join(os.path.dirname(sys.argv[3]), "AnimeNames.json"))


def plain(name):
    """For comparing names: letters and digits only."""
    folded = unicodedata.normalize("NFKD", name).casefold()
    return "".join(c for c in folded if c.isalnum())


def searchable(name):
    """Latin or Arabic letters (what can be typed on the keyboards people use)."""
    letters = [c for c in name if c.isalpha()]
    if not 2 <= len(letters) <= 70:
        return False
    if re.search(r"(?i)season|\b(part|cour)\b|\b(s|tv)\s?\d|\(\d{4}\)", name):
        return False  # «… Season 2»: the show's own names are enough
    return (all(ord(c) < 0x80 for c in letters)
            or all(0x600 <= ord(c) < 0x700 and c not in "پچژگکی" for c in letters))


def write_names(ids, by_mal, path):
    """{"names": [[...]], "tvdb://1": 0, "m:tmdb://2": 1, "imdb://tt3": 0}: id → its list."""
    rows = {}
    for row in ids:
        anime = by_mal.get(row.get("mal_id"))
        if not anime or row.get("type") in ("SPECIAL", "MUSIC", "CM", "PV"):
            continue
        tmdb = row.get("themoviedb_id")
        tmdb = tmdb if isinstance(tmdb, dict) else {"tv": tmdb}
        keys = [("tvdb://", row.get("tvdb_id")), ("tmdb://", tmdb.get("tv")),
                ("m:tmdb://", tmdb.get("movie")), ("imdb://", row.get("imdb_id"))]
        for prefix, values in keys:
            # A film listed under its series' TVDB id has names of its own.
            if row.get("type") == "MOVIE" and prefix in ("tvdb://", "tmdb://"):
                continue
            for value in values if isinstance(values, list) else [values]:
                if value:
                    rows.setdefault(prefix + str(value), []).append((row, anime))
    lists, number, out = [], {}, {}
    for key, found in sorted(rows.items()):
        found.sort(key=lambda p: ((p[0].get("season") or {}).get("tvdb") or 99, p[0]["mal_id"]))
        names, seen = [], set()
        for _, anime in found:
            # Short names («AOT») only when they're upper case or digits: noise otherwise.
            for name in [anime["title"]] + sorted(anime.get("synonyms", []), key=len):
                mark = plain(name)
                if mark in seen or not searchable(name):
                    continue
                if len(mark) < 4 and sum(c.isupper() for c in name) < 2 and name.isascii():
                    continue
                seen.add(mark)
                names.append(name)
                if len(names) >= 16:
                    break
            if len(names) >= 16:
                break
        if not names:
            continue
        mark = json.dumps(names, ensure_ascii=False)
        if mark not in number:
            number[mark] = len(lists)
            lists.append(names)
        out[key] = number[mark]
    with open(path, "w", encoding="utf-8") as file:
        json.dump({"names": lists, "ids": out}, file, ensure_ascii=False, separators=(",", ":"))
    print("names", len(lists), "ids", len(out))


main()
