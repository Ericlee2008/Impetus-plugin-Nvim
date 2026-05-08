import re
import sys

def strip_lines(text):
    out = []
    for line in text.splitlines():
        # Match line number prefix: 5 chars + tab
        m = re.match(r'^\s{0,5}\d+\t(.*)', line)
        if m:
            out.append(m.group(1))
        else:
            out.append(line)
    return '\n'.join(out) + '\n'

if __name__ == '__main__':
    mode = sys.argv[1] if len(sys.argv) > 1 else 'append'
    text = sys.stdin.read()
    cleaned = strip_lines(text)
    path = 'scripts/impetus_geometry_viewer.py'
    if mode == 'overwrite':
        with open(path, 'w', encoding='utf-8') as f:
            f.write(cleaned)
    else:
        with open(path, 'a', encoding='utf-8') as f:
            f.write(cleaned)
    print(f"Wrote {len(cleaned)} chars")
