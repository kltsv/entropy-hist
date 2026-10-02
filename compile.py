#!/usr/bin/env python3
"""Validate this repository's implementations against its app specs."""
import os
from pathlib import Path
os.chdir(Path(__file__).resolve().parent)
from tool.spec_graph import main
main()
