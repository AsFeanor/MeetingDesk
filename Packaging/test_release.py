import argparse
import base64
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET
import zipfile

spec = importlib.util.spec_from_file_location("release", Path(__file__).with_name("release.py"))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)

PUBLIC_KEY = base64.b64encode(bytes(range(32))).decode()
SIGNATURE = base64.b64encode(bytes(range(64))).decode()


class ReleaseValidationTests(unittest.TestCase):
    def settings(self, private=False, release_feed=True):
        repo = "example/MeetingDesk"
        return {"updateRepository": repo, "publicEDKey": PUBLIC_KEY,
                "privateUpdates": private, "signingAccount": "example/MeetingDesk",
                "feedURL": (f"https://api.github.com/repos/{repo}/contents/appcast.xml?ref=main" if private else
                            f"https://github.com/{repo}/releases/latest/download/appcast.xml" if release_feed else
                            f"https://raw.githubusercontent.com/{repo}/main/appcast.xml")}

    def info(self, settings):
        return {"CFBundleVersion": "5", "CFBundleShortVersionString": "0.3.0",
                "CFBundleIdentifier": "com.altugegesari.meetingdesk",
                "LSMinimumSystemVersion": "15.0", "SUPublicEDKey": PUBLIC_KEY,
                "SUFeedURL": settings["feedURL"], "SURequireSignedFeed": True,
                "SUVerifyUpdateBeforeExtraction": True}

    def test_config_rejects_partial_settings(self):
        with tempfile.TemporaryDirectory() as folder:
            project = Path(folder)
            (project / "Packaging").mkdir()
            (project / "Packaging/release-config.json").write_text(json.dumps({"updateRepository": "a/b"}))
            with patch.object(release, "PROJECT", project), patch.dict(os.environ, {}, clear=True):
                with self.assertRaisesRegex(release.ReleaseError, "together"):
                    release.config()

    def test_config_rejects_http_and_invalid_key(self):
        for field, value, expected in (("feedURL", "http://example.com/appcast.xml", "HTTPS"),
                                       ("publicEDKey", base64.b64encode(b"short").decode(), "32 bytes")):
            settings = self.settings()
            settings[field] = value
            with tempfile.TemporaryDirectory() as folder:
                project = Path(folder)
                (project / "Packaging").mkdir()
                (project / "Packaging/release-config.json").write_text(json.dumps(settings))
                with patch.object(release, "PROJECT", project), patch.dict(os.environ, {}, clear=True):
                    with self.assertRaisesRegex(release.ReleaseError, expected):
                        release.config()

    def test_configure_embeds_public_settings_and_disables_unattended_install(self):
        settings = self.settings()
        with tempfile.TemporaryDirectory() as folder:
            app = Path(folder) / "Toplanti.app"
            (app / "Contents").mkdir(parents=True)
            path = app / "Contents/Info.plist"
            path.write_bytes(plistlib.dumps(self.info(settings)))
            with patch.object(release, "config", return_value=settings):
                release.configure(app)
            info = plistlib.loads(path.read_bytes())
            self.assertEqual(info["MeetingDeskUpdateRepository"], settings["updateRepository"])
            self.assertTrue(info["SURequireSignedFeed"])
            self.assertTrue(info["SUVerifyUpdateBeforeExtraction"])
            self.assertFalse(info["SUAutomaticallyUpdate"])
            self.assertFalse(info["SUAllowsAutomaticUpdates"])

    def test_release_rejects_wrong_key_tag_and_build(self):
        settings = self.settings()
        for field, value in (("SUPublicEDKey", "different"), ("CFBundleVersion", "5.1"),
                             ("SUVerifyUpdateBeforeExtraction", False)):
            info = self.info(settings)
            info[field] = value
            with self.assertRaises(release.ReleaseError):
                release.validate_release_info(info, settings, settings["updateRepository"], "v0.3.0")
        with self.assertRaisesRegex(release.ReleaseError, "tag"):
            release.validate_release_info(self.info(settings), settings, settings["updateRepository"], "v0.2.2")

    def test_appcast_escapes_notes_and_has_no_external_release_notes(self):
        settings = self.settings()
        with tempfile.TemporaryDirectory() as folder:
            archive = Path(folder) / "Toplanti.zip"
            archive.write_bytes(b"archive")
            data = release.appcast_bytes(self.info(settings), archive, SIGNATURE,
                                         "https://github.com/example/MeetingDesk/releases/download/v0.3.0/Toplanti.zip",
                                         "https://github.com/example/MeetingDesk/releases/tag/v0.3.0", "A & B <test>")
        tree = ET.fromstring(data)
        self.assertEqual(tree.find("channel/item/description").text, "A & B <test>")
        self.assertEqual(tree.find("channel/item/enclosure").attrib["length"], "7")
        self.assertIsNone(tree.find(f".//{{{release.SPARKLE_NS}}}releaseNotesLink"))

    def test_resume_cannot_roll_back_a_newer_feed(self):
        feed = f'<rss xmlns:sparkle="{release.SPARKLE_NS}"><channel><item><sparkle:version>9</sparkle:version></item></channel></rss>'.encode()
        with self.assertRaisesRegex(release.ReleaseError, "increase"):
            release.validate_previous_build(feed, 5, True)
        release.validate_previous_build(feed, 9, True)
        with self.assertRaises(release.ReleaseError):
            release.validate_previous_build(feed, 9, False)

    def test_signing_secret_is_stdin_and_32_byte_seed_is_accepted(self):
        seed = base64.b64encode(bytes(range(32))).decode()
        with patch.dict(os.environ, {"SPARKLE_PRIVATE_KEY": seed}), \
             patch.object(release, "signer", return_value=Path("sign_update")), \
             patch.object(release, "run", return_value=SIGNATURE) as run:
            self.assertEqual(release.sign(["-p", "archive.zip"]), SIGNATURE)
            self.assertEqual(run.call_args.args[0], [Path("sign_update"), "--ed-key-file", "-", "-p", "archive.zip"])
            self.assertEqual(run.call_args.kwargs["input_text"], seed + "\n")
            self.assertNotIn(seed, map(str, run.call_args.args[0]))

    def test_unsupported_64_byte_key_is_rejected_before_signer_runs(self):
        secret = base64.b64encode(bytes(range(64))).decode()
        with patch.dict(os.environ, {"SPARKLE_PRIVATE_KEY": secret}), \
             patch.object(release, "signer", return_value=Path("sign_update")), \
             patch.object(release, "run") as run:
            with self.assertRaisesRegex(release.ReleaseError, "32/96-byte") as caught:
                release.sign(["-p", "archive.zip"])
            run.assert_not_called()
            self.assertNotIn(secret, str(caught.exception))

    def pipeline(self, *, private=False, fail_upload=False, fail_sign=False):
        settings = self.settings(private)
        events = []
        state = {"draft": True, "assets": []}
        with tempfile.TemporaryDirectory() as folder:
            project = Path(folder)
            app = project / "Toplanti.app"
            (app / "Contents").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(self.info(settings)))
            args = argparse.Namespace(app=app, update_repo=None, tag=None,
                                      notes_file=None, bootstrap=True, resume=False, prepare_only=False)

            def gh(endpoint, *, method="GET", body=None):
                events.append((method, endpoint))
                if endpoint == "repos/example/MeetingDesk" and method == "GET":
                    return {"private": private, "default_branch": "main"}
                if endpoint.endswith("/contents?ref=main"):
                    return [{"name": "README.md"}]
                if endpoint.endswith("/releases") and method == "GET":
                    return []
                if endpoint.endswith("/releases") and method == "POST":
                    return {"id": 100, "draft": True, "html_url": "https://github.com/example/MeetingDesk/releases/tag/v0.3.0"}
                if endpoint.endswith("/assets"):
                    return list(state["assets"])
                if method == "PATCH":
                    state["draft"] = False
                    return {}
                if "/releases/tags/" in endpoint:
                    return {"id": 100, "draft": state["draft"], "prerelease": False,
                            "assets": list(state["assets"]), "html_url": "https://github.com/example/MeetingDesk/releases/tag/v0.3.0"}
                if method == "PUT":
                    self.assertFalse(state["draft"], "Feed must never point to a draft release")
                    return {}
                raise AssertionError((method, endpoint))

            def run(command, **kwargs):
                command = list(map(str, command))
                if command[0] == "ditto":
                    with zipfile.ZipFile(command[-1], "w") as zipped:
                        zipped.write(app / "Contents/Info.plist", "Toplanti.app/Contents/Info.plist")
                if command[:3] == ["gh", "release", "upload"]:
                    events.append(("UPLOAD", Path(command[4]).name))
                    if fail_upload:
                        raise release.ReleaseError("upload failed")
                    asset_path = Path(command[4])
                    state["assets"].append({"id": 123 if asset_path.suffix == ".zip" else 124,
                                            "name": asset_path.name,
                                            "browser_download_url": "https://github.com/example/MeetingDesk/releases/download/v0.3.0/" + asset_path.name})
                return ""

            def sign(arguments):
                if fail_sign:
                    raise release.ReleaseError("signing failed")
                return SIGNATURE if "-p" in arguments else ""

            with patch.object(release, "PROJECT", project), patch.object(release, "config", return_value=settings), \
                 patch.object(release, "gh_api", side_effect=gh), patch.object(release, "run", side_effect=run), \
                 patch.object(release, "sign", side_effect=sign), patch.object(release, "verify_archive"):
                if fail_upload or fail_sign:
                    with self.assertRaises(release.ReleaseError):
                        release.publish(args)
                else:
                    release.publish(args)
        return events

    def test_public_feed_uploaded_before_release_is_published(self):
        events = self.pipeline()
        feed_upload = events.index(("UPLOAD", "appcast.xml"))
        published = events.index(("PATCH", "repos/example/MeetingDesk/releases/100"))
        self.assertLess(feed_upload, published)
        self.assertFalse(any(method == "PUT" for method, _ in events))

    def test_private_feed_written_only_after_stable_archive(self):
        events = self.pipeline(private=True)
        published = events.index(("PATCH", "repos/example/MeetingDesk/releases/100"))
        feed_write = events.index(("PUT", "repos/example/MeetingDesk/contents/appcast.xml"))
        self.assertLess(published, feed_write)

    def test_failed_upload_never_publishes_release_or_feed(self):
        events = self.pipeline(fail_upload=True)
        self.assertFalse(any(method in ("PATCH", "PUT") for method, _ in events))

    def test_failed_signing_never_creates_release(self):
        events = self.pipeline(fail_sign=True)
        self.assertFalse(any(method in ("POST", "PATCH", "PUT") for method, _ in events))


if __name__ == "__main__":
    unittest.main()
