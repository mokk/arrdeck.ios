#!/usr/bin/env python3
"""Builds App/Sources/Localizable.xcstrings from what the compiler says is
localisable plus Localization/da.json.

The catalog lives in the app, not the package: SwiftUI's Text("…") in a
package resolves against Bundle.main, so an app-level catalog covers every
screen without a `bundle:` argument on each call. The keys come from swiftc's
own -emit-localized-strings pass — the same one Xcode uses — so interpolated
strings get the exact "%lld of %lld torrents" form SwiftUI will look up.

    Scripts/localize.py          # regenerate the catalog
    Scripts/localize.py --check  # exit 1 if the committed catalog is stale

Rules for Localization/da.json: every extracted key needs an entry; null
means "same in Danish, leave it out of the catalog". Keys present only in
da.json (the badge states, looked up dynamically) are included too.
"""
import glob, json, os, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "App", "Sources", "Localizable.xcstrings")
DANISH = os.path.join(ROOT, "Localization", "da.json")


def extracted_keys():
    out = tempfile.mkdtemp(prefix="arrdeck-loc-")
    for target in ("ArrdeckData", "ArrdeckUI"):
        subprocess.run(
            ["swift", "build", "--target", target,
             "-Xswiftc", "-emit-localized-strings",
             "-Xswiftc", "-emit-localized-strings-path", "-Xswiftc", out],
            cwd=ROOT, check=True, capture_output=True,
        )
    keys = {}
    for path in glob.glob(os.path.join(out, "*.stringsdata")):
        data = json.load(open(path))
        source = data.get("source", "")
        if f"{ROOT}/Sources/" not in source:
            continue
        for entries in data.get("tables", {}).values():
            for entry in entries:
                keys.setdefault(entry["key"], set()).add(os.path.basename(source))
    return keys


def build_catalog(keys, danish):
    strings = {}
    for key in sorted(set(keys) | set(danish)):
        value = danish.get(key, "MISSING")
        if value is None:
            continue
        entry = {}
        if key not in keys:
            # looked up dynamically (badge states); Xcode must not prune it
            entry["extractionState"] = "manual"
        if value != "MISSING":
            entry["localizations"] = {"da": {"stringUnit": {"state": "translated", "value": value}}}
        strings[key] = entry
    return {"sourceLanguage": "en", "version": "1.0", "strings": strings}


def main():
    check = "--check" in sys.argv
    keys = extracted_keys()
    danish = json.load(open(DANISH))
    missing = sorted(k for k in keys if k not in danish)
    stale = sorted(k for k in danish if k not in keys and not k.startswith("_"))
    if missing:
        print("Missing Danish (add to Localization/da.json, null = untranslated):", file=sys.stderr)
        for key in missing:
            print(f"  {json.dumps(key, ensure_ascii=False)}: null,   # {', '.join(sorted(keys[key]))}", file=sys.stderr)
    catalog = build_catalog(keys, {k: v for k, v in danish.items() if not k.startswith("_")})
    rendered = json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    if check:
        current = open(CATALOG).read() if os.path.exists(CATALOG) else ""
        if current != rendered or missing:
            print("Localizable.xcstrings is out of date or incomplete; run Scripts/localize.py", file=sys.stderr)
            sys.exit(1)
        print(f"catalog current: {len(catalog['strings'])} strings")
        return
    open(CATALOG, "w").write(rendered)
    print(f"wrote {len(catalog['strings'])} strings; {len(missing)} missing Danish; {len(stale)} da.json-only keys")
    sys.exit(1 if missing else 0)


if __name__ == "__main__":
    main()
