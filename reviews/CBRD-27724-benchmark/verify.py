import csv
import hashlib
import json
import math
import statistics
import sys
from pathlib import Path

snapshot_path = Path(__file__).with_name("metrics.json")
data = json.loads(snapshot_path.read_text())
report = (snapshot_path.parents[2] / data["report"]).read_text()
cases = {case["name"]: case for case in data["primary_cases"]}
assert len(cases) == 18
assert data["acceptance"]["status"] == "complete"
assert all(data["acceptance"]["criteria"].values())
assert data["acceptance"]["primary_cases"] == len(cases)

for family in ("capacity", "tpcc", "scan"):
    drops = []
    p99_changes = []
    for pair in range(1, 4):
        rates = []
        latencies = []
        for side in ("A", "B"):
            measurement = cases[f"{family}-{pair}-{side}"]["measurement"]
            if family == "tpcc":
                assert measurement["unexpected_errors"] == 0
                assert measurement["errors"] == measurement["expected_aborts"]
                assert measurement["window_seconds"] == 300
                assert measurement["warmup_seconds"] == 120
                total = 0
                for name, values in measurement["per_type"].items():
                    assert values["attempted"] == values["completed"] + values["errors"]
                    assert values["completed"] == values["committed"] + values["rollbacks"]
                    assert math.isclose(values["committed_per_second"], values["committed"] / 300)
                    if name != "DELIVERY_BG":
                        total += values["committed_per_second"]
                rates.append(total)
                latencies.append(measurement["per_type"]["NEW_ORDER"]["p99_ms"])
            else:
                assert measurement["ignored_errors"] == measurement["reconnects"] == 0
                rates.append(measurement["events_per_second"])
                latencies.append(measurement["p99_ms"])
        drops.append((rates[0] - rates[1]) / rates[0] * 100)
        p99_changes.append((latencies[1] - latencies[0]) / latencies[0] * 100)
    assert f"{statistics.median(drops):.4f}%" in report
    assert f"{min(drops):.4f}~{max(drops):.4f}%" in report
    if family != "tpcc":
        assert f"{statistics.median(p99_changes):.4f}%" in report
    print(f"{family}: throughput drop median {statistics.median(drops):.4f}%, range {min(drops):.4f}~{max(drops):.4f}%")

control = data["control"]
assert control["applied_parameter"] == 0.1
assert all(all(value for key, value in row.items() if key != "primary_pair") for row in control["configuration_checks"])
for key, digits in (("new_order_nonrollback_per_second", 3), ("new_order_p99_ms", 0), ("mean_object_lock_wait_ms", 3), ("new_order_abort_pct_of_attempts", 4)):
    baseline = statistics.median(row[key] for row in control["baseline_B_metrics"])
    for number in (baseline, control["control_metrics"][key]):
        assert f"{number:.{digits}f}" in report
assert control["control_metrics"]["unknown_sql_errors"] == 0

diagnostic = data["diagnostic_tpcc32"]
assert diagnostic["coverage_verified"] and diagnostic["accounting_reconciled"]
counts = diagnostic["counts"]
assert counts["requests"] == sum(value for key, value in counts.items() if key != "requests")
assert counts["unclassified_success"] == 0
hits = counts["ordinary_hit"] + counts["simple_hit"]
misses = counts["ordinary_miss"] + counts["simple_miss"]
assert math.isclose(hits / (hits + misses) * 100, diagnostic["actual_hit_pct"])
assert f"{diagnostic['actual_hit_pct']:.4f}%" in report

if len(sys.argv) > 1:
    assert len(sys.argv) == 3 and sys.argv[1] == "--raw-root", "Usage: verify.py [--raw-root ATTEMPT_DIRECTORY]"
    raw_root = Path(sys.argv[2])
    for name, digest in data["source_sha256"].items():
        assert hashlib.sha256((raw_root / name).read_bytes()).hexdigest() == digest, name
    print("Preserved source JSON hashes match.")
    raw_measurements = [(case["name"], case["measurement"]) for case in cases.values() if case["family"] == "tpcc"]
    control_name = "intervention-tpcc-deadlock-100ms-retry"
    control_measurement = json.loads((raw_root / "heavy" / control_name / "load/measurement.json").read_text())
    assert control_measurement["per_type"]["NEW_ORDER"]["committed_per_second"] == control["control_metrics"]["new_order_nonrollback_per_second"]
    assert control_measurement["per_type"]["NEW_ORDER"]["p99_ms"] == control["control_metrics"]["new_order_p99_ms"]
    assert control_measurement["errors"] == control["control_metrics"]["all_type_sql_aborts"]
    raw_measurements.append((control_name, control_measurement))
    for name, expected in raw_measurements:
        observed = {}
        with (raw_root / "heavy" / name / "load/results/data/result.csv").open() as stream:
            for row in csv.DictReader(stream):
                if not 120000 <= float(row["elapsed"]) < 420000:
                    continue
                values = observed.setdefault(row["ttype"], {"attempted": 0, "errors": 0, "rollbacks": 0, "latencies": []})
                values["attempted"] += 1
                failed = row["error"].strip().lower() not in ("0", "false", "")
                code = int(row["error_code"])
                if failed:
                    assert code == -72, (name, code)
                    values["errors"] += 1
                else:
                    assert code == 0, (name, code)
                    values["latencies"].append(float(row["latency"]))
                    values["rollbacks"] += row["rbk"].strip().lower() in ("1", "true")
        assert observed.keys() == expected["per_type"].keys(), name
        for kind, values in observed.items():
            target = expected["per_type"][kind]
            for field in ("attempted", "errors", "rollbacks"):
                assert values[field] == target[field], (name, kind, field)
            latencies = sorted(values["latencies"])
            assert len(latencies) == target["completed"], (name, kind, "completed")
            assert len(latencies) - values["rollbacks"] == target["committed"], (name, kind, "committed")
            assert latencies[math.ceil(len(latencies) * 0.99) - 1] == target["p99_ms"], (name, kind, "p99")
        print(f"Raw CSV accounting and p99 match: {name}")

print("Verified 18 primary cases, reported medians and ranges, TPC-C accounting, control metrics and diagnostic hit ratio.")
