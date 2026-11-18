#!/usr/bin/env python3
"""Generates GarminKit/Sources/GarminDevices/DeviceCatalog.generated.swift from a Gadgetbridge checkout.

Usage:
    python3 scripts/generate_device_catalog.py /path/to/Gadgetbridge [-o OUTPUT]

Inputs, relative to the Gadgetbridge root:
    app/src/main/java/.../devices/garmin/**   every Garmin coordinator (Java and Kotlin)
    app/src/main/java/.../model/DeviceType.java   GARMIN_X(XCoordinator::new) links a coordinator to a DeviceType
    app/src/main/res/values/strings.xml      devicetype_garmin_* display names
    FitCodeGenerator/src/main/resources/fit_profile.json   FIT device table

Product numbers follow GarminProductNumbers: the FitDevice table generated from fit_profile.json,
keeping manufacturer 1 entries that have a DeviceType, keyed by product number.

Per coordinator, method values are resolved through the class hierarchy (Gadgetbridge's
supports*/defaultNewSyncProtocol/isExperimental/getAlarmSlotCount overrides). Literal returns and
calls to other overridden methods are followed. Device-dependent returns (GBApplication prefs,
GarminCapability checks, ternaries) are not evaluated: a feature flag that resolves to such a value is
emitted as absent and getAlarmSlotCount becomes nil, meaning the base class decides at runtime.

Only the Python standard library is used. The output is deterministic.
"""

import argparse
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

GARMIN_DIR = "app/src/main/java/nodomain/freeyourgadget/gadgetbridge/devices/garmin"
DEVICE_TYPE_JAVA = "app/src/main/java/nodomain/freeyourgadget/gadgetbridge/model/DeviceType.java"
STRINGS_XML = "app/src/main/res/values/strings.xml"
FIT_PROFILE_JSON = "FitCodeGenerator/src/main/resources/fit_profile.json"
DEFAULT_OUTPUT = Path(__file__).resolve().parent.parent / "GarminKit/Sources/GarminDevices/DeviceCatalog.generated.swift"

# Directory below devices/garmin -> GarminDeviceFamily case.
FAMILIES = {"watches": "watch", "bike": "bikeComputer", "hrm": "heartRateMonitor", "gps": "gpsHandheld"}

# Gadgetbridge supports* method -> GarminDeviceFeature case. Order is preserved in the output.
FEATURES = [
    ("supportsHeartRateMeasurement", "heartRate"),
    ("supportsHeartRateRestingMeasurement", "restingHeartRate"),
    ("supportsManualHeartRateMeasurement", "manualHeartRate"),
    ("supportsRealtimeData", "realtimeData"),
    ("supportsSpo2", "spo2"),
    ("supportsRespiratoryRate", "respiratoryRate"),
    ("supportsHrvMeasurement", "hrv"),
    ("supportsStressMeasurement", "stress"),
    ("supportsBodyEnergy", "bodyBattery"),
    ("supportsEcgMeasurement", "ecg"),
    ("supportsSleepMeasurement", "sleep"),
    ("supportsRemSleep", "remSleep"),
    ("supportsAwakeSleep", "awakeSleep"),
    ("supportsSleepScore", "sleepScore"),
    ("supportsPai", "intensityMinutes"),
    ("supportsActiveCalories", "activeCalories"),
    ("supportsVO2Max", "vo2Max"),
    ("supportsRacePrediction", "racePrediction"),
    ("supportsTrainingStatus", "trainingStatus"),
    ("supportsTrainingLoad", "trainingLoad"),
    ("supportsRecordedActivities", "recordedActivities"),
    ("supportsDataFetching", "dataFetching"),
    ("supportsWeather", "weather"),
    ("supportsCalendarEvents", "calendarEvents"),
    ("supportsSolarCharging", "solarCharging"),
    ("supportsFindDevice", "findDevice"),
    ("supportsMusicInfo", "music"),
    ("supportsAppNotifications", "appNotifications"),
    ("supportsCallControl", "callControl"),
    ("supportsSmsReply", "smsReply"),
    ("supportsSendWaypoint", "sendWaypoint"),
]

# Strings and comments are masked before structural scanning so braces inside them do not count.
COMMENT_OR_STRING = re.compile(r'//[^\n]*|/\*.*?\*/|"(?:[^"\\\n]|\\.)*"|\'(?:[^\'\\\n]|\\.)*\'', re.S)
STRING_LITERAL = re.compile(r'"(?:[^"\\\n]|\\.)*"|\'(?:[^\'\\\n]|\\.)*\'')
CLASS_DECL = re.compile(r'\bclass\s+(\w+)([^{]*)\{')
MEMBER_DECL = re.compile(r'(\w+)\s*\(([^()]*)\)\s*(?::\s*[\w<>?.,]+)?\s*\{')
RETURN_EXPR = re.compile(r'\breturn\b([^;{}]*)')
PATTERN_CALL = re.compile(r'Pattern\.compile\(\s*"((?:[^"\\]|\\.)*)"\s*\)')
RESOURCE_REF = re.compile(r'R\.string\.(\w+)')
DEVICE_CALL = re.compile(r'(\w+)\(\s*device\s*\)')
DEVICE_TYPE_LINK = re.compile(r'(\w+)\(\s*(\w+)::new\s*\)')


class Coordinator:
    def __init__(self, name, parent, abstract, rel_path):
        self.name = name
        self.parent = parent
        self.abstract = abstract
        self.rel_path = rel_path
        self.methods = {}  # method name -> raw return expression, or None when the body has several returns


def strip_comments(src):
    def repl(m):
        text = m.group(0)
        if text.startswith(("//", "/*")):
            return re.sub(r"[^\n]", " ", text)
        return text
    return COMMENT_OR_STRING.sub(repl, src)


def mask_strings(src):
    def repl(m):
        text = m.group(0)
        return text[0] + re.sub(r"[^\n]", "_", text[1:-1]) + text[-1]
    return STRING_LITERAL.sub(repl, src)


def top_level_only(body):
    """Blanks everything nested inside braces, keeping positions and the outermost braces."""
    out = []
    depth = 0
    for c in body:
        if c == "{":
            out.append(c if depth == 0 else " ")
            depth += 1
        elif c == "}":
            depth -= 1
            out.append(c if depth == 0 else " ")
        else:
            out.append(c if depth == 0 else " ")
    return "".join(out)


def unescape_java(literal):
    return re.sub(r"\\(.)", r"\1", literal)


def parse_coordinators(garmin_dir):
    classes = {}
    for path in sorted(garmin_dir.rglob("*")):
        if path.suffix not in (".java", ".kt"):
            continue
        clean = strip_comments(path.read_text(encoding="utf-8"))
        masked = mask_strings(clean)
        rel = path.relative_to(garmin_dir).as_posix()
        for m in CLASS_DECL.finditer(masked):
            name, rest = m.group(1), m.group(2)
            line_start = masked.rfind("\n", 0, m.start()) + 1
            abstract = re.search(r"\babstract\b", masked[line_start:m.start()]) is not None
            parent_match = re.search(r"\bextends\s+(\w+)", rest) or re.search(r":\s*(\w+)\s*\(", rest)
            coordinator = Coordinator(name, parent_match.group(1) if parent_match else None, abstract, rel)
            body_start = m.end()
            body_end = find_closing_brace(masked, body_start - 1)
            members = top_level_only(masked[body_start:body_end])
            for member in MEMBER_DECL.finditer(members):
                member_name = member.group(1)
                if member_name in coordinator.methods:
                    continue
                member_open = body_start + member.end() - 1
                member_close = find_closing_brace(masked, member_open)
                returns = list(RETURN_EXPR.finditer(masked[member_open:member_close + 1]))
                if len(returns) == 1:
                    start, end = returns[0].span(1)
                    coordinator.methods[member_name] = clean[member_open + start:member_open + end].strip()
                else:
                    coordinator.methods[member_name] = None
            if name in classes:
                sys.exit(f"duplicate class name {name}: {classes[name].rel_path} and {rel}")
            classes[name] = coordinator
    return classes


def find_closing_brace(text, open_idx):
    depth = 0
    for i in range(open_idx, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return i
    sys.exit("unbalanced braces")


def hierarchy(classes, name):
    while name is not None and name in classes:
        yield classes[name]
        name = classes[name].parent


def resolve(classes, concrete, method, depth=0):
    """Value of method on concrete: a bool, int, str (regex or resource name) or None when unknown."""
    if depth > 8:
        return None
    for owner in hierarchy(classes, concrete):
        if method in owner.methods:
            return evaluate(classes, concrete, owner.methods[method], depth)
    return None


def evaluate(classes, concrete, expr, depth):
    if expr is None:
        return None
    if expr in ("true", "false"):
        return expr == "true"
    if re.fullmatch(r"-?\d+", expr):
        return int(expr)
    m = PATTERN_CALL.fullmatch(expr)
    if m:
        return unescape_java(m.group(1))
    m = RESOURCE_REF.fullmatch(expr)
    if m:
        return m.group(1)
    m = DEVICE_CALL.fullmatch(expr)
    if m:
        # A call to another supports* method with the device argument dispatches on the concrete class.
        return resolve(classes, concrete, m.group(1), depth + 1)
    return None


def load_strings(path):
    root = ET.parse(path).getroot()
    return {s.get("name"): (s.text or "") for s in root.iter("string")}


def load_device_types(path):
    text = strip_comments(path.read_text(encoding="utf-8"))
    link = {}
    for m in DEVICE_TYPE_LINK.finditer(text):
        link[m.group(2)] = m.group(1)
    return link


def load_products(path):
    """Mirrors GarminProductNumbers: manufacturer 1 FIT devices that have a DeviceType, keyed by product."""
    devices = json.loads(path.read_text(encoding="utf-8"))["devices"]
    products = {}
    for device in devices:
        if device.get("manufacturer") == 1 and device.get("type"):
            device_type = device["type"].split(".")[-1]
            products.setdefault(device_type, set()).add(device["product"])
    return products


def swift_raw_string(value):
    if '"#' in value:
        sys.exit(f"pattern contains a raw-string terminator: {value}")
    return f'#"{value}"#'


def swift_string(value):
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def build_models(root):
    garmin_dir = root / GARMIN_DIR
    classes = parse_coordinators(garmin_dir)
    strings = load_strings(root / STRINGS_XML)
    device_type_for_class = load_device_types(root / DEVICE_TYPE_JAVA)
    products_for_device_type = load_products(root / FIT_PROFILE_JSON)

    models = []
    unlinked = []
    for name, coordinator in sorted(classes.items()):
        if coordinator.abstract:
            continue
        pattern = resolve(classes, name, "getSupportedDeviceName")
        resource = resolve(classes, name, "getDeviceNameResource")
        if not isinstance(pattern, str) or not isinstance(resource, str):
            continue  # helper base or hierarchy root without a device
        if resource not in strings:
            sys.exit(f"{name}: string resource {resource} missing from strings.xml")
        family = FAMILIES.get(coordinator.rel_path.split("/")[0])
        if family is None:
            sys.exit(f"{name}: unknown family directory in {coordinator.rel_path}")
        device_type = device_type_for_class.get(name)
        if device_type is None:
            unlinked.append(name)
        features = [case for java, case in FEATURES if resolve(classes, name, java) is True]
        alarm_slots = resolve(classes, name, "getAlarmSlotCount")
        models.append({
            "id": resource.replace("devicetype_", "").lower(),
            "display_name": strings[resource],
            "family": family,
            "pattern": pattern,
            "products": sorted(products_for_device_type.get(device_type, set())) if device_type else [],
            "device_type": device_type,
            "features": features,
            "alarm_slots": alarm_slots if isinstance(alarm_slots, int) else None,
            "new_sync_protocol": resolve(classes, name, "defaultNewSyncProtocol") is True,
            "experimental": resolve(classes, name, "isExperimental") is True,
            "coordinator": name,
        })

    ids = [m["id"] for m in models]
    duplicates = {i for i in ids if ids.count(i) > 1}
    if duplicates:
        sys.exit(f"duplicate model ids: {sorted(duplicates)}")
    if unlinked:
        print(f"warning: no DeviceType link for {len(unlinked)} coordinators: {unlinked}", file=sys.stderr)
    return models


def check_product_conflicts(models):
    owners = {}
    for m in models:
        for product in m["products"]:
            owners.setdefault(product, set()).add(m["id"])
    for product, ids in sorted(owners.items()):
        if len(ids) > 1:
            print(f"warning: product {product} belongs to several models: {sorted(ids)}", file=sys.stderr)


def render_swift(models):
    lines = [
        "// Generated by scripts/generate_device_catalog.py from Gadgetbridge's Garmin coordinators,",
        "// GarminProductNumbers' FIT device table and strings.xml. Do not edit by hand; rerun the script.",
        "",
        "extension GarminDeviceCatalog {",
        "    static let models: [GarminDeviceModel] = [",
    ]
    for m in models:
        products = ", ".join(str(p) for p in m["products"])
        features = ", ".join(f".{f}" for f in m["features"])
        alarm = "nil" if m["alarm_slots"] is None else str(m["alarm_slots"])
        lines += [
            "        GarminDeviceModel(",
            f"            id: {swift_string(m['id'])},",
            f"            displayName: {swift_string(m['display_name'])},",
            f"            family: .{m['family']},",
            f"            bluetoothNamePattern: {swift_raw_string(m['pattern'])},",
            f"            productNumbers: [{products}],",
            f"            features: [{features}],",
            f"            alarmSlotCount: {alarm},",
            f"            usesNewSyncProtocol: {str(m['new_sync_protocol']).lower()},",
            f"            isExperimental: {str(m['experimental']).lower()},",
            f"            gadgetbridgeCoordinator: {swift_string(m['coordinator'])}",
            "        ),",
        ]
    lines += ["    ]", "}", ""]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("gadgetbridge", type=Path, help="Gadgetbridge checkout root")
    parser.add_argument("-o", "--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()

    root = args.gadgetbridge.resolve()
    if not (root / GARMIN_DIR).is_dir():
        sys.exit(f"not a Gadgetbridge checkout: {root}")

    models = build_models(root)
    check_product_conflicts(models)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(render_swift(models), encoding="utf-8")

    by_family = {}
    for m in models:
        by_family[m["family"]] = by_family.get(m["family"], 0) + 1
    no_products = [m["id"] for m in models if not m["products"]]
    print(f"wrote {len(models)} models to {args.output}", file=sys.stderr)
    print(f"by family: {dict(sorted(by_family.items()))}", file=sys.stderr)
    if no_products:
        print(f"{len(no_products)} models without FIT product numbers: {no_products}", file=sys.stderr)


if __name__ == "__main__":
    main()
