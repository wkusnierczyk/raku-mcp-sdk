#!/usr/bin/env python3
"""Post-process RaCoCo coverage output into JSON and Markdown reports.

Reads coverage-report/report.txt (RaCoCo v2 format) and report.html,
produces timestamped coverage-report-YYYY-MM-DD-hhmm.{json,md,html} files,
then removes the originals.

Usage: python3 tools/coverage-report.py [--coverage-dir coverage-report]
"""

import json
import os
import re
import shutil
import sys
from datetime import datetime


def parse_report_txt(path):
    """Parse RaCoCo v2 report.txt into structured data."""
    modules = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('RaCoCo') or line.startswith('Filename'):
                continue
            parts = line.split(' | ')
            if len(parts) < 3:
                continue
            filename = parts[0]
            coverage_str = parts[1].replace('%', '').strip()
            try:
                coverage = float(coverage_str)
            except ValueError:
                continue

            # Parse line hits: "line hit-time line hit-time ..."
            hit_pairs = []
            for segment in parts[2:]:
                tokens = segment.strip().split()
                for i in range(0, len(tokens) - 1, 2):
                    try:
                        line_no = int(tokens[i])
                        hits = int(tokens[i + 1])
                        hit_pairs.append({"line": line_no, "hits": hits})
                    except (ValueError, IndexError):
                        pass

            total_lines = len(hit_pairs)
            covered_lines = sum(1 for p in hit_pairs if p["hits"] > 0)

            modules.append({
                "module": filename,
                "coverage": coverage,
                "totalLines": total_lines,
                "coveredLines": covered_lines,
            })

    # Compute overall totals
    total = sum(m["totalLines"] for m in modules)
    covered = sum(m["coveredLines"] for m in modules)
    overall = round(covered / total * 100, 1) if total > 0 else 0.0

    return {
        "totalCoverage": overall,
        "totalLines": total,
        "coveredLines": covered,
        "modules": sorted(modules, key=lambda m: -m["coverage"]),
    }


def write_json(data, path):
    with open(path, 'w') as f:
        json.dump(data, f, indent=2)
        f.write('\n')


def write_markdown(data, path):
    lines = [
        f"# Coverage Report",
        f"",
        f"**Total coverage: {data['totalCoverage']}%** ({data['coveredLines']}/{data['totalLines']} lines)",
        f"",
        f"| Module | Coverage | Lines | Covered |",
        f"|--------|----------|-------|---------|",
    ]
    for m in data["modules"]:
        lines.append(
            f"| {m['module']} | {m['coverage']}% | {m['totalLines']} | {m['coveredLines']} |"
        )
    lines.append("")
    with open(path, 'w') as f:
        f.write('\n'.join(lines))


def main():
    coverage_dir = "coverage-report"
    for i, arg in enumerate(sys.argv[1:]):
        if arg == "--coverage-dir" and i + 1 < len(sys.argv) - 1:
            coverage_dir = sys.argv[i + 2]

    report_txt = os.path.join(coverage_dir, "report.txt")
    report_html = os.path.join(coverage_dir, "report.html")

    if not os.path.exists(report_txt):
        print(f"Error: {report_txt} not found", file=sys.stderr)
        sys.exit(1)

    # Parse
    data = parse_report_txt(report_txt)
    timestamp = datetime.now().strftime("%Y-%m-%d-%H%M")
    data["generatedAt"] = datetime.now().isoformat()

    # Output file names
    base = os.path.join(coverage_dir, f"coverage-report-{timestamp}")
    json_path = f"{base}.json"
    md_path = f"{base}.md"
    html_path = f"{base}.html"

    # Write JSON and Markdown
    write_json(data, json_path)
    write_markdown(data, md_path)

    # Copy HTML with timestamp
    if os.path.exists(report_html):
        shutil.copy2(report_html, html_path)
        os.remove(report_html)

    # Remove original report.txt
    os.remove(report_txt)

    # Print summary
    print(f"Coverage: {data['totalCoverage']}%")
    print(f"Generated: {json_path}")
    print(f"Generated: {md_path}")
    if os.path.exists(html_path):
        print(f"Generated: {html_path}")


if __name__ == "__main__":
    main()
