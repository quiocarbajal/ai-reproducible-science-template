#!/usr/bin/env python3
"""
template_script.py - Template Python Analysis Script

Demonstrates In-Script Version Declaration:
Keeping the code and its environment requirements locked together in the same Git commit.

Tested Environment & Core Versions:
  - Python: 3.11.x (tested on 3.11.8)
  - pandas: >= 2.0.0 (tested with 2.2.1)
  - numpy: >= 1.24.0 (tested with 1.26.4)
  - pysam: >= 0.22.0
  - bedtools (CLI): >= 2.31.0

Execution:
  python3 template_script.py
"""

import os
import sys

def main():
    print(f"Running script with Python {sys.version.split()[0]}")

    # Check for raw data accessed via data_tracker symlinks
    raw_data_dir = "raw_data"
    if not os.path.isdir(raw_data_dir):
        print(f"Warning: {raw_data_dir}/ does not exist. Run './scripts/data_tracker.sh link'.")
        return

    print("Pipeline ready.")

if __name__ == "__main__":
    main()
