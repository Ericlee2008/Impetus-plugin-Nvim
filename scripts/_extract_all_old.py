import re

with open('scripts/_modify_viewer.py', encoding='utf-8') as f:
    content = f.read()

# Find all old_* = '''...''' patterns
pattern = r"(old_\w+)\s*=\s*('''|\"\"\")(.*?)\2"
matches = re.findall(pattern, content, re.DOTALL)

for name, quote, text in matches:
    print(f"\n=== {name} ===")
    print(f"Length: {len(text)} chars, {text.count(chr(10))} lines")
    print(f"First 200 chars: {repr(text[:200])}")
    print(f"Last 200 chars: {repr(text[-200:])}")
