#!/usr/bin/env python3
"""Syntax check on any platform. Not a replacement for an Xcode build."""
from pathlib import Path
import sys
try:
    import tree_sitter
    import tree_sitter_swift
except ImportError:
    print("Install optional check dependencies with python3 -m pip install tree-sitter tree-sitter-swift")
    sys.exit(2)
parser = tree_sitter.Parser(tree_sitter.Language(tree_sitter_swift.language()))
root = Path(__file__).resolve().parent.parent
bad = []
for path in sorted((root / "Margherita").glob("*.swift")):
    tree = parser.parse(path.read_bytes())
    def visit(node):
        if node.type == "ERROR" or node.is_missing:
            bad.append((str(path.relative_to(root)), node.start_point, node.type))
        for child in node.children:
            visit(child)
    visit(tree.root_node)
for issue in bad:
    print(*issue)
print(f"{len(list((root / 'Margherita').glob('*.swift')))} Swift files parsed; {len(bad)} syntax errors")
sys.exit(bool(bad))
