#!/usr/bin/env python3
"""Regenerate Spektrafilm.xcodeproj/project.pbxproj from the filesystem.

    Tools/gen-project.py            # write
    Tools/gen-project.py --check    # exit 1 if the checked-in file is stale

Object ids are derived from paths (first 24 hex chars of a sha1), so running
this twice produces a byte-identical file. Every Swift/Metal file under
`Spektrafilm/` joins the app target; everything under `SpektrafilmTests/` joins
the unit-test target. `Resources/` is added as a folder reference so anything
dropped in it ships in the bundle without touching this script.

**The C++ render engine** (RFC-014) joins the app target too, as sources
rather than as a prebuilt library: `ENGINE_SOURCES` below lists every
translation unit under `engine/src/`, referenced relative to this project, and
they compile as C++20 alongside the Swift. One target, not two, because the
only thing a separate static-library target would add here is a second place
for the include paths to drift.

Two things about the engine that are *not* handled here, on purpose:

  * its Metal kernels are compiled by `engine/build.sh`, not by Xcode. The app
    target sets `MTL_FAST_MATH = YES` for its own canvas shader, and letting
    the engine's kernels inherit that is RFC-014 §5.1 trap 1 -- a silent
    1.1e-5 drift in `exp` and fma contraction, past the float32 bar. The
    engine refuses to start if it detects it.
  * its baked constants and profiles are synced into `Spektrafilm/Resources/
    engine/` by `engine/build.sh bundle`, and ride along in the folder
    reference above.

So: `engine/build.sh bundle` before an Xcode build, and the pre-build script
phase below says so if it was not.
"""
from __future__ import annotations

import hashlib
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT.parents[1] / "engine"
APP = "Spektrafilm"
TESTS = "SpektrafilmTests"
BUNDLE_ID = "com.hanze.spektrafilm"
MACOS = "15.0"

# The version, in one place.
#
# `Info.plist` used to carry the literal strings `0.2` and `2`, which is why
# they were still `0.2` and `2` — nothing derived them and nothing noticed.
# They are build settings now and the plist references them, so a release
# bumps one line here (HANDOFF-DISTRIBUTION §2.6).
MARKETING_VERSION = "0.3"
BUILD_NUMBER = "3"

# Signing, from the environment, because a Developer ID certificate is not in
# this repository and must not be.
#
# The default is ad-hoc, which is what a development build has always used and
# what Gatekeeper refuses everywhere except the machine that made it. A release
# passes the real identity and team:
#
#     SPEKTRAFILM_SIGN_IDENTITY="Developer ID Application: NAME (TEAMID)" \
#     SPEKTRAFILM_TEAM_ID=TEAMID Tools/gen-project.py
#
# `Tools/package.sh` does exactly that and then notarises. Hardened runtime is
# on unconditionally: notarisation requires it, and a Debug build that differs
# from the shipped one in *how it is hardened* is a Debug build that cannot
# prove the release will launch (HANDOFF-DISTRIBUTION §2.1, §2.2).
SIGN_IDENTITY = os.environ.get("SPEKTRAFILM_SIGN_IDENTITY", "-")
TEAM_ID = os.environ.get("SPEKTRAFILM_TEAM_ID", "")


def uid(key: str) -> str:
    return hashlib.sha1(key.encode()).hexdigest()[:24].upper()


def engine_sources() -> list[Path]:
    """Every engine translation unit, in a stable order."""
    return sorted((ENGINE / "src").rglob("*.cpp"))


def relative_to_project(path: Path) -> str:
    """A path spelled relative to the .xcodeproj's directory.

    The engine lives outside this project's tree, so its file references use
    `sourceTree = SOURCE_ROOT` and a `../..` path. Absolute paths would work
    on exactly one machine.
    """
    return os.path.relpath(path, ROOT)


def file_type(p: Path) -> str:
    return {".swift": "sourcecode.swift", ".metal": "sourcecode.metal",
            ".cpp": "sourcecode.cpp.cpp", ".h": "sourcecode.c.h", ".hpp": "sourcecode.cpp.h",
            ".plist": "text.plist.xml", ".entitlements": "text.plist.entitlements",
            ".xcassets": "folder.assetcatalog", ".md": "net.daringfireball.markdown",
            ".py": "text.script.python", ".sh": "text.script.sh"}.get(p.suffix, "folder")


class Project:
    def __init__(self):
        self.objects: list[str] = []

    def add(self, id_: str, body: str, comment: str = ""):
        c = f" /* {comment} */" if comment else ""
        self.objects.append(f"\t\t{id_}{c} = {body};")

    # groups -------------------------------------------------------------
    def group(self, dir_: Path, target_files: list[tuple[str, Path]], name: str | None = None,
              is_root=False) -> str:
        gid = uid("group:" + str(dir_))
        children = []
        for entry in sorted(dir_.iterdir(), key=lambda p: (p.is_file(), p.name.lower())):
            if entry.name.startswith(".") or entry.name == "Spektrafilm.xcodeproj":
                continue
            if entry.is_dir() and entry.suffix not in (".xcassets",) and entry.name != "Resources":
                if entry.name in ("build", "DerivedData"):
                    continue
                children.append((self.group(entry, target_files), entry.name))
            else:
                fid = uid("file:" + str(entry))
                ft = file_type(entry)
                if entry.name == "Resources":
                    self.add(fid, f"{{isa = PBXFileReference; lastKnownFileType = folder; path = Resources; sourceTree = \"<group>\"; }}", "Resources")
                else:
                    self.add(fid, f"{{isa = PBXFileReference; lastKnownFileType = {ft}; path = \"{entry.name}\"; sourceTree = \"<group>\"; }}", entry.name)
                children.append((fid, entry.name))
                target_files.append((fid, entry))
        kids = ",\n".join(f"\t\t\t\t{cid} /* {cname} */" for cid, cname in children)
        path_key = "path" if not is_root else "path"
        self.add(gid, f"{{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{kids}\n\t\t\t);\n\t\t\t{path_key} = \"{name or dir_.name}\";\n\t\t\tsourceTree = \"<group>\";\n\t\t}}", name or dir_.name)
        return gid


def build() -> str:
    p = Project()
    app_files: list[tuple[str, Path]] = []
    test_files: list[tuple[str, Path]] = []
    app_group = p.group(ROOT / APP, app_files)
    test_group = p.group(ROOT / TESTS, test_files)
    tools_files: list[tuple[str, Path]] = []
    tools_group = p.group(ROOT / "Tools", tools_files)

    # The engine's translation units, as references outside the project tree.
    engine_files: list[tuple[str, Path]] = []
    engine_children = []
    for src in engine_sources():
        fid = uid("file:engine:" + str(src))
        p.add(fid, f"{{isa = PBXFileReference; lastKnownFileType = sourcecode.cpp.cpp; "
                   f"name = \"{src.name}\"; path = \"{relative_to_project(src)}\"; "
                   f"sourceTree = SOURCE_ROOT; }}", src.name)
        engine_children.append((fid, src.name))
        engine_files.append((fid, src))
    engine_group = uid("group:engine")
    kids = ",\n".join(f"\t\t\t\t{cid} /* {cname} */" for cid, cname in engine_children)
    p.add(engine_group, f"{{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{kids}\n\t\t\t);"
                        f"\n\t\t\tname = Engine;\n\t\t\tsourceTree = \"<group>\";\n\t\t}}", "Engine")

    app_product = uid("product:app")
    test_product = uid("product:tests")
    p.add(app_product, f"{{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {APP}.app; sourceTree = BUILT_PRODUCTS_DIR; }}", f"{APP}.app")
    p.add(test_product, f"{{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = {TESTS}.xctest; sourceTree = BUILT_PRODUCTS_DIR; }}", f"{TESTS}.xctest")
    products = uid("group:products")
    p.add(products, f"{{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{app_product},\n\t\t\t\t{test_product}\n\t\t\t);\n\t\t\tname = Products;\n\t\t\tsourceTree = \"<group>\";\n\t\t}}", "Products")
    main_group = uid("group:main")
    p.add(main_group, f"{{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{app_group},\n\t\t\t\t{engine_group},\n\t\t\t\t{test_group},\n\t\t\t\t{tools_group},\n\t\t\t\t{products}\n\t\t\t);\n\t\t\tsourceTree = \"<group>\";\n\t\t}}")

    def phase(kind: str, files: list[tuple[str, Path]], pred, tag: str) -> str:
        ids = []
        for fid, path in files:
            if pred(path):
                bid = uid(f"build:{tag}:{path}")
                p.add(bid, f"{{isa = PBXBuildFile; fileRef = {fid}; }}", path.name)
                ids.append(f"\t\t\t\t{bid} /* {path.name} */")
        pid = uid(f"phase:{tag}:{kind}")
        p.add(pid, f"{{\n\t\t\tisa = {kind};\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n" + ",\n".join(ids) + "\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}", tag)
        return pid

    is_src = lambda q: q.suffix in (".swift", ".metal", ".cpp")
    is_res = lambda q: q.suffix == ".xcassets" or q.name == "Resources"
    app_sources = phase("PBXSourcesBuildPhase", app_files + engine_files, is_src, "app-sources")
    app_resources = phase("PBXResourcesBuildPhase", app_files, is_res, "app-resources")
    app_frameworks = phase("PBXFrameworksBuildPhase", [], lambda q: False, "app-frameworks")
    # The test bundle is standalone (no TEST_HOST): it compiles every app
    # source except the @main file, so the tests run without launching the
    # app and without the test-host injection that crashed SwiftUI's
    # environment root on macOS 26.
    shared = [(fid, path) for fid, path in app_files + engine_files
              if is_src(path) and path.name != "SpektrafilmApp.swift"]
    test_sources = phase("PBXSourcesBuildPhase", test_files + shared, is_src, "test-sources")
    test_resources = phase("PBXResourcesBuildPhase", test_files + [(fid, path) for fid, path in app_files if is_res(path)], is_res, "test-resources")
    test_frameworks = phase("PBXFrameworksBuildPhase", [], lambda q: False, "test-frameworks")

    # The engine's build settings. `MTL_FAST_MATH` stays YES for the app's own
    # canvas shader; the engine's kernels never go through Xcode's metal
    # compiler, so it cannot reach them.
    engine_cfg = {
        "CLANG_CXX_LANGUAGE_STANDARD": '"c++20"',
        "CLANG_CXX_LIBRARY": '"libc++"',
        "GCC_C_LANGUAGE_STANDARD": "c11",
        # A parenthesised list, not a run of quoted strings: pbxproj accepts
        # `( "a", "b" )` or one quoted string, and a bare sequence makes the
        # whole project unreadable with a message that names line 1.
        "HEADER_SEARCH_PATHS": "(\n" + "".join(
            f'\t\t\t\t\t"$(SRCROOT)/../../engine/{sub}",\n'
            for sub in ("include", "src", "src/core", "third_party/metal-cpp")
        ) + "\t\t\t\t)",
        "SWIFT_OBJC_BRIDGING_HEADER": f'"{APP}/Service/{APP}-Bridging-Header.h"',
        "OTHER_LDFLAGS": '"-framework Metal -framework QuartzCore"',
        # metal-cpp's headers use `objc_msgSend` directly and manage their own
        # retain/release; ARC must not be applied to them. The Swift side is
        # unaffected -- Swift's memory management is not this setting.
        "CLANG_ENABLE_OBJC_ARC": "NO",
    }

    common = {
        **engine_cfg,
        "SWIFT_VERSION": "6.0",
        "SWIFT_STRICT_CONCURRENCY": "complete",
        "MACOSX_DEPLOYMENT_TARGET": MACOS,
        "SDKROOT": "macosx",
        "ARCHS": "arm64",
        "ONLY_ACTIVE_ARCH": "YES",
        "CODE_SIGN_STYLE": "Manual" if TEAM_ID else "Automatic",
        "CODE_SIGN_IDENTITY": f'"{SIGN_IDENTITY}"',
        "DEVELOPMENT_TEAM": f'"{TEAM_ID}"',
        "CLANG_ENABLE_MODULES": "YES",
        # Required for notarisation, and on in both configurations so a Debug
        # build exercises the same hardening the release ships with.
        "ENABLE_HARDENED_RUNTIME": "YES",
        "MARKETING_VERSION": MARKETING_VERSION,
        "CURRENT_PROJECT_VERSION": BUILD_NUMBER,
        "SWIFT_EMIT_LOC_STRINGS": "NO",
        "GENERATE_INFOPLIST_FILE": "NO",
        "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
        "MTL_FAST_MATH": "YES",
        "COMBINE_HIDPI_IMAGES": "YES",
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
    }
    app_cfg = {
        **common,
        "PRODUCT_NAME": APP,
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
        "INFOPLIST_FILE": f"{APP}/Info.plist",
        "CODE_SIGN_ENTITLEMENTS": f"{APP}/{APP}.entitlements",
        "LD_RUNPATH_SEARCH_PATHS": '"$(inherited) @executable_path/../Frameworks"',
        "ENABLE_PREVIEWS": "YES",
    }
    test_cfg = {
        **common,
        "PRODUCT_NAME": TESTS,
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID + ".tests",
        "GENERATE_INFOPLIST_FILE": "YES",
        "LD_RUNPATH_SEARCH_PATHS": '"$(inherited) @executable_path/../Frameworks @loader_path/../Frameworks"',
    }

    def cfg(tag: str, name: str, settings: dict, extra: dict) -> str:
        cid = uid(f"cfg:{tag}:{name}")
        merged = {**settings, **extra}
        body = "\n".join(f"\t\t\t\t{k} = {v};" for k, v in sorted(merged.items()))
        p.add(cid, f"{{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{body}\n\t\t\t}};\n\t\t\tname = {name};\n\t\t}}", name)
        return cid

    debug = {"SWIFT_OPTIMIZATION_LEVEL": '"-Onone"', "DEBUG_INFORMATION_FORMAT": "dwarf",
             "ENABLE_TESTABILITY": "YES", "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
             "GCC_OPTIMIZATION_LEVEL": "0"}
    release = {"SWIFT_OPTIMIZATION_LEVEL": '"-O"', "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"',
               "SWIFT_COMPILATION_MODE": "wholemodule"}

    def cfg_list(tag: str, settings: dict) -> str:
        d = cfg(tag, "Debug", settings, debug)
        r = cfg(tag, "Release", settings, release)
        lid = uid(f"cfglist:{tag}")
        p.add(lid, f"{{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t{d} /* Debug */,\n\t\t\t\t{r} /* Release */\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}}", tag)
        return lid

    # A pre-build check, not a build step -- see Tools/check-bundle-resources.sh
    # for why it only reports rather than bakes. Kept as a script *file* so the
    # pbxproj carries one line rather than an escaped shell program, and so the
    # check can be run on its own. It covers the engine's baked resources and
    # the licence texts the bundle is obliged to carry.
    check_script = uid("phase:app:check-resources")
    p.add(check_script,
          "{\n\t\t\tisa = PBXShellScriptBuildPhase;\n\t\t\tbuildActionMask = 2147483647;"
          "\n\t\t\tfiles = (\n\t\t\t);\n\t\t\tinputPaths = (\n\t\t\t);"
          "\n\t\t\tname = \"Check bundled resources\";\n\t\t\toutputPaths = (\n\t\t\t);"
          "\n\t\t\trunOnlyForDeploymentPostprocessing = 0;"
          "\n\t\t\tshellPath = /bin/sh;"
          "\n\t\t\tshellScript = \"\\\"$SRCROOT/Tools/check-bundle-resources.sh\\\"\\n\";"
          "\n\t\t}", "Check bundled resources")

    app_target = uid("target:app")
    test_target = uid("target:tests")
    dep = uid("dep:tests->app")
    proxy = uid("proxy:tests->app")
    project = uid("project")
    p.add(proxy, f"{{\n\t\t\tisa = PBXContainerItemProxy;\n\t\t\tcontainerPortal = {project};\n\t\t\tproxyType = 1;\n\t\t\tremoteGlobalIDString = {app_target};\n\t\t\tremoteInfo = {APP};\n\t\t}}")
    p.add(dep, f"{{\n\t\t\tisa = PBXTargetDependency;\n\t\t\ttarget = {app_target};\n\t\t\ttargetProxy = {proxy};\n\t\t}}")

    p.add(app_target, f"{{\n\t\t\tisa = PBXNativeTarget;\n\t\t\tbuildConfigurationList = {cfg_list('app', app_cfg)};\n\t\t\tbuildPhases = (\n\t\t\t\t{check_script},\n\t\t\t\t{app_sources},\n\t\t\t\t{app_frameworks},\n\t\t\t\t{app_resources}\n\t\t\t);\n\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t);\n\t\t\tname = {APP};\n\t\t\tproductName = {APP};\n\t\t\tproductReference = {app_product};\n\t\t\tproductType = \"com.apple.product-type.application\";\n\t\t}}", APP)
    p.add(test_target, f"{{\n\t\t\tisa = PBXNativeTarget;\n\t\t\tbuildConfigurationList = {cfg_list('tests', test_cfg)};\n\t\t\tbuildPhases = (\n\t\t\t\t{test_sources},\n\t\t\t\t{test_frameworks},\n\t\t\t\t{test_resources}\n\t\t\t);\n\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t);\n\t\t\tname = {TESTS};\n\t\t\tproductName = {TESTS};\n\t\t\tproductReference = {test_product};\n\t\t\tproductType = \"com.apple.product-type.bundle.unit-test\";\n\t\t}}", TESTS)

    proj_cfg = cfg_list("project", {"SWIFT_VERSION": "6.0", "MACOSX_DEPLOYMENT_TARGET": MACOS,
                                    "SDKROOT": "macosx", "ALWAYS_SEARCH_USER_PATHS": "NO",
                                    "CLANG_ENABLE_OBJC_ARC": "YES", "ENABLE_STRICT_OBJC_MSGSEND": "YES",
                                    "GCC_NO_COMMON_BLOCKS": "YES", "ENABLE_USER_SCRIPT_SANDBOXING": "NO"})
    p.add(project, f"{{\n\t\t\tisa = PBXProject;\n\t\t\tattributes = {{\n\t\t\t\tBuildIndependentTargetsInParallel = 1;\n\t\t\t\tLastSwiftUpdateCheck = 1600;\n\t\t\t\tLastUpgradeCheck = 1600;\n\t\t\t\tTargetAttributes = {{\n\t\t\t\t\t{test_target} = {{\n\t\t\t\t\t\tTestTargetID = {app_target};\n\t\t\t\t\t}};\n\t\t\t\t}};\n\t\t\t}};\n\t\t\tbuildConfigurationList = {proj_cfg};\n\t\t\tcompatibilityVersion = \"Xcode 14.0\";\n\t\t\tdevelopmentRegion = en;\n\t\t\thasScannedForEncodings = 0;\n\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase\n\t\t\t);\n\t\t\tmainGroup = {main_group};\n\t\t\tproductRefGroup = {products};\n\t\t\tprojectDirPath = \"\";\n\t\t\tprojectRoot = \"\";\n\t\t\ttargets = (\n\t\t\t\t{app_target},\n\t\t\t\t{test_target}\n\t\t\t);\n\t\t}}", "Project object")

    body = "\n".join(p.objects)
    return f"// !$*UTF8*$!\n{{\n\tarchiveVersion = 1;\n\tclasses = {{\n\t}};\n\tobjectVersion = 56;\n\tobjects = {{\n{body}\n\t}};\n\trootObject = {project} /* Project object */;\n}}\n"


def main() -> None:
    out = ROOT / f"{APP}.xcodeproj" / "project.pbxproj"
    text = build()
    if "--check" in sys.argv:
        if not out.exists() or out.read_text() != text:
            print("project.pbxproj is stale; run Tools/gen-project.py")
            sys.exit(1)
        print("project.pbxproj is current")
        return
    out.parent.mkdir(exist_ok=True)
    out.write_text(text)
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
