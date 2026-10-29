#!/usr/bin/env python3
"""A photo eval with known answers: freely licensed photos from Wikimedia Commons, a handful per subject, saved under
neutral names (p001.jpg…: a name like "cat.jpg" would hand keyword search the answer), and evals/photos.local.json,
which `murmur-engine eval` reads. Run it once; then index the folder and compare the search old and new (README.md).

Standard library only. Usage: make_photo_eval.py [--to ~/MurmurTestbed/photo-eval] [--per 5]
"""
import argparse
import json
import os
import sys
import time
import urllib.parse
import urllib.request

API = "https://commons.wikimedia.org/w/api.php"
AGENT = "MurmurPhotoEval/1.0 (https://github.com/shubhamsWEB/murmur-app; search quality testing)"

# What to look for, the Commons search that finds it, and how people ask for it. Each query expects any photo of its
# subject; the other subjects are the distractors.
SUBJECTS = [
    ("cat", "domestic cat photograph", ["cat photo", "my cat", "a cat sleeping"]),
    ("dog", "dog photograph", ["dog photo", "picture of a dog"]),
    ("beach", "sandy beach sea photograph", ["beach photos", "the beach"]),
    ("mountain", "mountain landscape snow peak", ["mountains", "photo of snowy mountains"]),
    ("pizza", "pizza food photograph", ["pizza", "food photo of pizza"]),
    ("bicycle", "bicycle parked street photograph", ["bicycle", "photo of my bike"]),
    ("laptop", "laptop computer on desk photograph", ["laptop on a desk", "computer photo"]),
    ("receipt", "shop receipt paper photograph", ["receipt", "photo of a bill"]),
    ("sunset", "sunset sky photograph", ["sunset", "sunset photos"]),
    ("cake", "birthday cake candles", ["birthday cake", "cake photo"]),
    ("car", "car parked street photograph", ["car photo", "picture of a car"]),
    ("flower", "flower close-up photograph", ["flowers", "photo of a flower"]),
    ("airplane", "airplane aircraft flying photograph", ["airplane", "plane photo"]),
    ("train", "train railway station photograph", ["train", "photo at a railway station"]),
    ("whiteboard", "whiteboard writing meeting", ["whiteboard", "photo of the whiteboard"]),
    ("temple", "hindu temple india photograph", ["temple", "temple photos"]),
]


def get(params):
    url = API + "?" + urllib.parse.urlencode({**params, "format": "json"})
    request = urllib.request.Request(url, headers={"User-Agent": AGENT})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def photos(search, count):
    """Up to `count` JPEG photos for `search`: their 1024-pixel copies' addresses."""
    data = get({"action": "query", "generator": "search", "gsrsearch": f"filetype:bitmap {search}",
                "gsrnamespace": 6, "gsrlimit": count * 4, "prop": "imageinfo", "iiprop": "url|mime|size",
                "iiurlwidth": 1024})
    pages = sorted(data.get("query", {}).get("pages", {}).values(), key=lambda page: page.get("index", 0))
    out = []
    for page in pages:
        info = (page.get("imageinfo") or [{}])[0]
        if info.get("mime") != "image/jpeg" or min(info.get("width", 0), info.get("height", 0)) < 400:
            continue
        out.append(info.get("thumburl") or info.get("url"))
        if len(out) == count:
            break
    return out


def download(url, path):
    request = urllib.request.Request(url, headers={"User-Agent": AGENT})
    with urllib.request.urlopen(request, timeout=60) as response, open(path, "wb") as file:
        file.write(response.read())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--to", default="~/MurmurTestbed/photo-eval")
    parser.add_argument("--per", type=int, default=5)
    parser.add_argument("--eval", default=os.path.join(os.path.dirname(__file__), "..", "..", "evals", "photos.local.json"))
    args = parser.parse_args()
    folder = os.path.expanduser(args.to)
    os.makedirs(folder, exist_ok=True)
    answers, number = {}, 0
    for subject, search, _ in SUBJECTS:
        names = []
        for url in photos(search, args.per):
            number += 1
            name = f"p{number:03d}.jpg"
            try:
                download(url, os.path.join(folder, name))
                names.append(name)
            except Exception as error:   # one photo that won't download doesn't stop the rest
                print(f"  skipped one {subject} photo: {error}", file=sys.stderr)
            time.sleep(0.2)   # gently: Commons asks for it
        answers[subject] = names
        print(f"{subject:11} {len(names)} photos")
    queries = [{"q": query, "expect": answers[subject], "tag": subject}
               for subject, _, asked in SUBJECTS for query in asked if answers[subject]]
    base = args.to if args.to.startswith("~") else folder
    os.makedirs(os.path.dirname(os.path.abspath(args.eval)), exist_ok=True)
    with open(args.eval, "w") as file:
        json.dump({"base": base, "queries": queries}, file, indent=2)
    print(f"\n{number} photos in {folder}\n{len(queries)} queries in {os.path.abspath(args.eval)}")


if __name__ == "__main__":
    main()
