#!/usr/bin/env python3
"""Check module mappings and repository selection without building or uploading."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

BUILD = pathlib.Path(__file__).resolve().parents[1] / "build"


def call_helper(name, *args):
    """Call a pure build helper with its required arguments."""
    return subprocess.check_output(
        ["bash", "-c", 'source "$1"; shift; "$@"', "test",
         str(BUILD / "functions.bash"), name, *args],
        cwd=BUILD, text=True,
    ).strip()


class ModuleRouting(unittest.TestCase):
    def test_extension_locations(self):
        """Each Pro extension belongs inside its own product's shared module."""
        expected = {
            "cloudmin-gpl": "cloudmin-gpl,server-manager,gpl,,,",
            "cloudmin-pro": "cloudmin-pro,server-manager,pro,cloudmin-gpl,server-manager/pro,Commercial License",
            "virtualmin-gpl": "virtualmin-gpl,virtual-server,gpl,,,",
            "virtualmin-pro": "virtualmin-pro,virtual-server,pro,virtualmin-gpl,virtual-server/pro,Commercial License",
        }
        for module, mapping in expected.items():
            with self.subTest(module=module):
                self.assertEqual(call_helper("resolve_module_info", module), mapping)

    def test_related_editions(self):
        """A change to either edition rebuilds both packages in its family."""
        for family in ["cloudmin", "virtualmin"]:
            for edition, other in [("gpl", "pro"), ("pro", "gpl")]:
                module = f"{family}-{edition}"
                with self.subTest(module=module):
                    self.assertEqual(
                        call_helper("get_related_modules", module),
                        f"{module} {family}-{other}",
                    )
        self.assertEqual(call_helper("get_related_modules", "webmin-jailkit"), "webmin-jailkit")

    def test_repository_targets(self):
        """Cloudmin uses its repository; existing module destinations stay intact."""
        for module in ["cloudmin-gpl", "cloudmin-pro", "virtualmin-gpl", "virtualmin-pro", "webmin-jailkit"]:
            with self.subTest(module=module):
                expected = "cloudmin.dev" if module.startswith("cloudmin-") else "virtualmin.dev"
                self.assertEqual(call_helper("get_module_repo_target", module), expected)

    def test_package_entry_points(self):
        """Both builders select the correct editions and metadata before cleanup."""
        for package_format in ["deb", "rpm"]:
            for family in ["cloudmin", "virtualmin"]:
                for edition, other in [("gpl", "pro"), ("pro", "gpl")]:
                    with self.subTest(package_format=package_format, family=family, edition=edition):
                        self.check_entry_point(package_format, family, edition, other)

    def check_entry_point(self, package_format, family, edition, other):
        """Run the builder's entry point with local stubs for all side effects."""
        script = (BUILD / f"build-module-{package_format}.bash").read_text()
        self.assertEqual(script.count("# Main\n"), 1)
        main = script.split("# Main\n", 1)[1]
        with tempfile.TemporaryDirectory(prefix="module-routing-") as temporary:
            work = pathlib.Path(temporary)
            shutil.copyfile(BUILD / "module-groups.txt", work / "module-groups.txt")
            entry = work / "main.bash"
            entry.write_text(main)
            harness = r'''set -euo pipefail
source "$1"
entry="$2"
shift 2
VIRTUALMIN_ORG_AUTH_URL=https://example.invalid/virtualmin
ROOT_REPOS="$PWD/packages"
build() { printf 'build:%s\n' "$1"; }
get_flag() { return 1; }
cloud_upload() { printf 'upload\n'; }
cloud_sign_and_build_repos_auto() { printf 'sign:%s\n' "$1"; }
purge_dir() { :; }
postcmd() { return "$1"; }
source "$entry"
'''
            result = subprocess.check_output(
                ["bash", "-c", harness, "test", str(BUILD / "functions.bash"),
                 str(entry), f"{family}-{edition}"], cwd=work, text=True,
            )
            events = [line for line in result.splitlines()
                      if line.startswith(("build:", "sign:")) or line == "upload"]
            self.assertEqual(events, [f"build:{family}-{edition}", f"build:{family}-{other}",
                                      "upload", f"sign:{family}.dev"])


if __name__ == "__main__":
    unittest.main()
