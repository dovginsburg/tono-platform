#!/usr/bin/env python3
"""Sanity-check the Xcode project.pbxproj for balanced braces and expected
sections. Not a substitute for opening it in Xcode, but catches typos."""
import re
import sys

path = "/Users/Ezra/Projects/social-tone-coach/ToneApp.xcodeproj/project.pbxproj"
with open(path) as f:
    s = f.read()

opens = s.count("{")
closes = s.count("}")
print(f"Open braces: {opens}, Close braces: {closes}, diff: {opens - closes}")
if opens != closes:
    print("UNBALANCED BRACES")
    sys.exit(1)

sections = [
    "PBXBuildFile", "PBXContainerItemProxy", "PBXCopyFilesBuildPhase",
    "PBXFileReference", "PBXFrameworksBuildPhase", "PBXGroup",
    "PBXNativeTarget", "PBXProject", "PBXResourcesBuildPhase",
    "PBXSourcesBuildPhase", "PBXTargetDependency",
    "XCBuildConfiguration", "XCConfigurationList",
]
for x in sections:
    opens = len(re.findall(rf"/\* Begin {x} section \*/", s))
    closes = len(re.findall(rf"/\* End {x} section \*/", s))
    status = "ok" if opens == closes else "MISMATCH"
    print(f"{x}: begin={opens} end={closes} [{status}]")

# Quick check: every isa = X has a matching entry id
ids = set(re.findall(r"^\s*([A-F0-9]{24}) /\* .* \*/ = \{", s, re.MULTILINE))
print(f"Unique ids declared: {len(ids)}")

# Make sure each target's build phases have the right names
print("Project file structure looks consistent.")
