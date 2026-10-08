#!/usr/bin/env python3
"""Build configuration and signed GitHub/Sparkle releases; never reads meetings."""
import argparse
import base64
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
from urllib.parse import quote, urlparse
import xml.etree.ElementTree as ET
import zipfile

PROJECT = Path(__file__).resolve().parent.parent
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)


class ReleaseError(Exception):
    pass


def run(arguments, *, input_text=None):
    # Private signing material is supplied over stdin and is never printed.
    result = subprocess.run([str(a) for a in arguments], input=input_text,
                            text=True, capture_output=True)
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip()
        secret = os.environ.get("SPARKLE_PRIVATE_KEY", "")
        if secret:
            detail = detail.replace(secret, "[redacted]")
            detail = detail.replace(secret.strip(), "[redacted]")
        raise ReleaseError(f"{Path(str(arguments[0])).name} failed: {detail}")
    return result.stdout.strip()


def config():
    path = PROJECT / "Packaging/release-config.json"
    value = json.loads(path.read_text()) if path.exists() else {}
    for field, environment in (("updateRepository", "UPDATE_REPOSITORY"),
                               ("feedURL", "SU_FEED_URL"),
                               ("publicEDKey", "SU_PUBLIC_ED_KEY")):
        if environment in os.environ:
            value[field] = os.environ[environment].strip()
    if "PRIVATE_UPDATES" in os.environ:
        raw = os.environ["PRIVATE_UPDATES"].lower()
        if raw not in ("true", "false", "1", "0"):
            raise ReleaseError("PRIVATE_UPDATES must be true or false")
        value["privateUpdates"] = raw in ("true", "1")
    value.setdefault("privateUpdates", False)
    value.setdefault("signingAccount", "AsFeanor/MeetingDesk")
    for name in ("updateRepository", "feedURL", "publicEDKey"):
        value.setdefault(name, "")
    repo = value["updateRepository"]
    if repo and not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
        raise ReleaseError("updateRepository must be owner/repository")
    if value["feedURL"] and urlparse(value["feedURL"]).scheme != "https":
        raise ReleaseError("Update feed must use HTTPS")
    if value["publicEDKey"]:
        try:
            public = base64.b64decode(value["publicEDKey"], validate=True)
        except ValueError:
            raise ReleaseError("publicEDKey must be a base64 Ed25519 public key")
        if len(public) != 32:
            raise ReleaseError("publicEDKey must contain 32 bytes")
    if any(value[name] for name in ("updateRepository", "feedURL", "publicEDKey")):
        if not all(value[name] for name in ("updateRepository", "feedURL", "publicEDKey")):
            raise ReleaseError("Set updateRepository, feedURL and publicEDKey together")
    return value


def configure(app):
    settings = config()
    path = app / "Contents/Info.plist"
    with path.open("rb") as handle:
        info = plistlib.load(handle)
    mappings = {"SUFeedURL": "feedURL", "SUPublicEDKey": "publicEDKey",
                "MeetingDeskUpdateRepository": "updateRepository"}
    for plist_name, field in mappings.items():
        if settings[field]:
            info[plist_name] = settings[field]
        else:
            info.pop(plist_name, None)
    info["MeetingDeskPrivateUpdates"] = settings["privateUpdates"]
    info["SURequireSignedFeed"] = True
    info["SUVerifyUpdateBeforeExtraction"] = True
    info["SUEnableAutomaticChecks"] = bool(settings["feedURL"])
    info["SUAutomaticallyUpdate"] = False
    info["SUAllowsAutomaticUpdates"] = False
    with path.open("wb") as handle:
        plistlib.dump(info, handle)


def signer():
    override = os.environ.get("SPARKLE_SIGN_UPDATE")
    path = Path(override) if override else PROJECT / ".build/artifacts/sparkle/Sparkle/bin/sign_update"
    if not path.is_file():
        raise ReleaseError("Sparkle sign_update is missing. Run Packaging/build.sh first.")
    return path


def sign(arguments):
    secret = os.environ.get("SPARKLE_PRIVATE_KEY")
    command = [signer()]
    if secret:
        # Prevalidate to prevent Sparkle echoing a malformed secret in errors.
        try:
            raw = base64.b64decode(secret.strip(), validate=True)
        except ValueError:
            raise ReleaseError("SPARKLE_PRIVATE_KEY is not valid base64")
        if len(raw) not in (32, 96):
            raise ReleaseError("SPARKLE_PRIVATE_KEY must be a Sparkle 32/96-byte export")
        command += ["--ed-key-file", "-"]
        input_text = secret.strip() + "\n"
    else:
        command += ["--account", os.environ.get("SPARKLE_KEYCHAIN_ACCOUNT", config()["signingAccount"])]
        input_text = None
    return run(command + list(arguments), input_text=input_text)


def verify_archive(archive, public_key, signature):
    # Verify against the public key embedded in the app, rather than merely
    # verifying that sign_update used some existing key from the Keychain.
    swift = """import Foundation
import CryptoKit
let p = CommandLine.arguments
let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: p[2])!)
let data = try Data(contentsOf: URL(fileURLWithPath: p[1]))
guard key.isValidSignature(Data(base64Encoded: p[3])!, for: data) else { exit(1) }
"""
    cache = PROJECT / ".build/release-verify-cache"
    cache.mkdir(parents=True, exist_ok=True)
    run(["swift", "-module-cache-path", cache, "-e", swift,
         archive, public_key, signature])


def gh_api(endpoint, *, method="GET", body=None):
    command = ["gh", "api", endpoint, "--method", method,
               "-H", "Accept: application/vnd.github+json",
               "-H", "X-GitHub-Api-Version: 2022-11-28"]
    if body is not None:
        command += ["--input", "-"]
    output = run(command, input_text=json.dumps(body) if body is not None else None)
    return json.loads(output) if output else None


def appcast_bytes(info, archive, signature, asset_url, release_url, notes):
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Toplantı güncellemeleri"
    ET.SubElement(channel, "link").text = release_url
    ET.SubElement(channel, "description").text = "Toplantı macOS uygulamasının kararlı sürümleri"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"Toplantı {info['CFBundleShortVersionString']}"
    ET.SubElement(item, "link").text = release_url
    ET.SubElement(item, "description").text = notes
    ET.SubElement(item, f"{{{SPARKLE_NS}}}version").text = info["CFBundleVersion"]
    ET.SubElement(item, f"{{{SPARKLE_NS}}}shortVersionString").text = info["CFBundleShortVersionString"]
    ET.SubElement(item, f"{{{SPARKLE_NS}}}minimumSystemVersion").text = info["LSMinimumSystemVersion"]
    ET.SubElement(item, "pubDate").text = datetime.datetime.now(datetime.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")
    ET.SubElement(item, "enclosure", {"url": asset_url,
                  f"{{{SPARKLE_NS}}}edSignature": signature,
                  "length": str(archive.stat().st_size),
                  "type": "application/octet-stream"})
    ET.indent(rss, space="  ")
    return ET.tostring(rss, encoding="utf-8", xml_declaration=True)


def validate_release_info(info, settings, repo, tag):
    if not settings["publicEDKey"]:
        raise ReleaseError("Update signing must be configured before release")
    if tag != "v" + info["CFBundleShortVersionString"]:
        raise ReleaseError("Release tag must match the app version: v" + info["CFBundleShortVersionString"])
    if info.get("SUPublicEDKey") != settings["publicEDKey"]:
        raise ReleaseError("App's public signing key does not match release configuration")
    if info.get("SUFeedURL") != settings["feedURL"]:
        raise ReleaseError("App feed URL does not match release configuration")
    if repo != settings["updateRepository"]:
        raise ReleaseError("Release repository must match configured updateRepository")
    if not str(info["CFBundleVersion"]).isdigit():
        raise ReleaseError("CFBundleVersion must be an increasing integer")
    if not info.get("SURequireSignedFeed") or not info.get("SUVerifyUpdateBeforeExtraction"):
        raise ReleaseError("App must verify signed feeds and archives before extraction")


def validate_previous_build(feed_bytes, build, resume):
    old_feed = ET.fromstring(feed_bytes)
    versions = [element.text for element in old_feed.findall(f".//{{{SPARKLE_NS}}}version")]
    if not versions or any(not str(value).isdigit() for value in versions):
        raise ReleaseError("Published appcast has no valid integer build number")
    previous = max(map(int, versions))
    if previous > build or (previous == build and not resume):
        raise ReleaseError("Build number must increase beyond the published feed")


def publish(args):
    settings = config()
    repo = args.update_repo or settings["updateRepository"]
    app = args.app.resolve()
    with (app / "Contents/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    tag = args.tag or "v" + info["CFBundleShortVersionString"]
    validate_release_info(info, settings, repo, tag)
    repository = gh_api(f"repos/{repo}")
    if bool(repository["private"]) != settings["privateUpdates"]:
        raise ReleaseError("Repository visibility differs from privateUpdates")
    branch = repository["default_branch"]
    private_feed = f"https://api.github.com/repos/{repo}/contents/appcast.xml?ref={quote(branch)}"
    raw_feed = f"https://raw.githubusercontent.com/{repo}/{quote(branch)}/appcast.xml"
    release_feed = f"https://github.com/{repo}/releases/latest/download/appcast.xml"
    expected_feeds = [private_feed] if settings["privateUpdates"] else [release_feed, raw_feed]
    if settings["feedURL"] not in expected_feeds:
        raise ReleaseError("feedURL must point to this repository's appcast.xml")
    feed_in_release = settings["feedURL"] == release_feed
    run(["codesign", "--verify", "--deep", "--strict", app])
    notes = args.notes_file.read_text().strip() if args.notes_file else f"Toplantı {info['CFBundleShortVersionString']}"
    contents_path = f"repos/{repo}/contents/appcast.xml?ref={quote(branch)}"
    existing_feed = None
    # A missing feed is allowed only for the explicitly requested bootstrap.
    if feed_in_release:
        if args.bootstrap:
            releases = gh_api(f"repos/{repo}/releases")
            if any(not release["draft"] and not release["prerelease"] for release in releases):
                raise ReleaseError("Bootstrap is only allowed before the first stable release")
        else:
            previous_release = gh_api(f"repos/{repo}/releases/latest")
            with tempfile.TemporaryDirectory() as folder:
                run(["gh", "release", "download", previous_release["tag_name"], "--repo", repo,
                     "--pattern", "appcast.xml", "--dir", folder])
                validate_previous_build((Path(folder) / "appcast.xml").read_bytes(),
                                        int(info["CFBundleVersion"]), args.resume)
    elif not args.bootstrap:
        existing_feed = gh_api(contents_path)
        validate_previous_build(base64.b64decode(existing_feed["content"]),
                                int(info["CFBundleVersion"]), args.resume)
    else:
        files = gh_api(f"repos/{repo}/contents?ref={quote(branch)}")
        if any(entry["name"] == "appcast.xml" for entry in files):
            raise ReleaseError("Bootstrap is only allowed when no feed has been published")
    output = PROJECT / "dist/releases" / tag
    output.mkdir(parents=True, exist_ok=True)
    archive = output / f"Toplanti-{info['CFBundleShortVersionString']}.zip"
    if not (args.resume and archive.exists()):
        if archive.exists():
            archive.unlink()
        run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive])
    with zipfile.ZipFile(archive) as zipped:
        archived_info = plistlib.loads(zipped.read("Toplanti.app/Contents/Info.plist"))
    for name in ("CFBundleVersion", "CFBundleShortVersionString", "CFBundleIdentifier", "SUFeedURL", "SUPublicEDKey"):
        if archived_info.get(name) != info.get(name):
            raise ReleaseError("Existing archive configuration differs from the provided app")
    signature = sign(["-p", archive])
    try:
        if len(base64.b64decode(signature, validate=True)) != 64:
            raise ValueError()
    except ValueError:
        raise ReleaseError("sign_update did not produce an Ed25519 signature")
    verify_archive(archive, settings["publicEDKey"], signature)
    # All local signing validation happens before any release is created.
    if args.prepare_only:
        print(f"Validated signed archive: {archive}")
        return
    if args.resume:
        release = gh_api(f"repos/{repo}/releases/tags/{quote(tag)}")
    else:
        release = gh_api(f"repos/{repo}/releases", method="POST", body={
            "tag_name": tag, "target_commitish": branch, "name": f"Toplantı {info['CFBundleShortVersionString']}",
            "body": notes, "draft": True, "prerelease": False})
    assets = gh_api(f"repos/{repo}/releases/{release['id']}/assets")
    matching = [asset for asset in assets if asset["name"] == archive.name]
    if matching:
        # Never overwrite an archive users may already have downloaded.
        asset = matching[0]
        with tempfile.TemporaryDirectory() as folder:
            run(["gh", "release", "download", tag, "--repo", repo, "--pattern", archive.name, "--dir", folder])
            remote_hash = hashlib.sha256((Path(folder) / archive.name).read_bytes()).digest()
        if remote_hash != hashlib.sha256(archive.read_bytes()).digest():
            raise ReleaseError("Existing release asset differs; increment version/build rather than replacing it")
    else:
        if not release["draft"]:
            raise ReleaseError("A published release cannot gain a new update archive; create a new version")
        run(["gh", "release", "upload", tag, archive, "--repo", repo])
        assets = gh_api(f"repos/{repo}/releases/{release['id']}/assets")
        asset = next(asset for asset in assets if asset["name"] == archive.name)
    asset_url = (f"https://api.github.com/repos/{repo}/releases/assets/{asset['id']}"
                 if settings["privateUpdates"] else asset["browser_download_url"])
    feed = output / "appcast.xml"
    feed.write_bytes(appcast_bytes(info, archive, signature, asset_url, release["html_url"], notes))
    sign([feed])
    sign(["--verify", feed])
    if feed_in_release:
        if release["draft"]:
            run(["gh", "release", "upload", tag, feed, "--repo", repo, "--clobber"])
        elif not any(item["name"] == "appcast.xml" for item in assets):
            raise ReleaseError("Published release has no signed feed; publish a new version")
    # Publish the immutable asset first. A later feed failure leaves old updates
    # working; resume can finish without replacing the signed archive.
    if release["draft"]:
        gh_api(f"repos/{repo}/releases/{release['id']}", method="PATCH",
               body={"draft": False, "make_latest": "true"})
    stable = gh_api(f"repos/{repo}/releases/tags/{quote(tag)}")
    if stable["draft"] or stable["prerelease"]:
        raise ReleaseError("Stable release was not published; feed was left untouched")
    if not any(item["id"] == asset["id"] for item in stable["assets"]):
        raise ReleaseError("Published release is missing its archive; feed was left untouched")
    if feed_in_release:
        if not any(item["name"] == "appcast.xml" for item in stable["assets"]):
            raise ReleaseError("Published release is missing its signed feed")
    else:
        # GitHub Contents PUT replaces the feed in one commit and checks its SHA.
        body = {"message": f"Publish signed appcast for {tag}", "branch": branch,
                "content": base64.b64encode(feed.read_bytes()).decode("ascii")}
        if existing_feed:
            body["sha"] = existing_feed["sha"]
        gh_api(f"repos/{repo}/contents/appcast.xml", method="PUT", body=body)
    print(f"Published {stable['html_url']}\nSigned feed: {settings['feedURL']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    configure_parser = commands.add_parser("configure", help="Inject public update settings into an unsigned bundle")
    configure_parser.add_argument("--app", type=Path, required=True)
    release_parser = commands.add_parser("publish", help="Sign and publish a stable app and atomic feed")
    release_parser.add_argument("--app", type=Path, required=True)
    release_parser.add_argument("--update-repo", help="May differ from the private source repository")
    release_parser.add_argument("--tag")
    release_parser.add_argument("--notes-file", type=Path)
    release_parser.add_argument("--bootstrap", action="store_true", help="Allow the first release when the feed does not exist")
    release_parser.add_argument("--resume", action="store_true", help="Finish an interrupted release without replacing its archive")
    release_parser.add_argument("--prepare-only", action="store_true", help="Validate and sign without creating releases or modifying the feed")
    args = parser.parse_args()
    try:
        if args.command == "configure":
            configure(args.app)
        else:
            publish(args)
    except (ReleaseError, OSError, ValueError, KeyError, ET.ParseError) as error:
        print(f"Release stopped: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
