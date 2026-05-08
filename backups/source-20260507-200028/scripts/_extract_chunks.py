import re

with open('scripts/_modify_viewer.py', encoding='utf-8') as f:
    content = f.read()

def extract_triple_quoted(marker):
    start = content.find(marker)
    if start == -1:
        return None
    q_start = start + len(marker)
    quote_char = content[q_start]
    end_marker = quote_char * 3
    end = content.find(end_marker, q_start + 3)
    if end == -1:
        return None
    return content[q_start + 3:end]

old_show_window = extract_triple_quoted("old_show_window = ")
old_row_block = extract_triple_quoted("old_row_block = ")

with open('scripts/_chunk_show_window.py', 'w', encoding='utf-8') as f:
    f.write(old_show_window)

with open('scripts/_chunk_row_block.py', 'w', encoding='utf-8') as f:
    f.write(old_row_block)

print(f"show_window chunk: {len(old_show_window)} chars, {old_show_window.count(chr(10))} lines")
print(f"row_block chunk: {len(old_row_block)} chars, {old_row_block.count(chr(10))} lines")
