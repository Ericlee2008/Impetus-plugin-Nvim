import subprocess
import sys

blobs = [
    '8a5da20f73ccbb57b9c04248aa0f9ce7d3e270ad',
    'b243adf8e4f8eb7572d8b9052c2da6a28f78d367',
    '109308b30e851845caf3da17c00b29a5ca6a22b4',
    '0f04a47a78061b90144b99877d16aff89054e454',
    '1c06d3dcc44113dc2d7a7221be9c13112c7a34b2',
    '6de477e6fe7ac1334d66e5568f261270fb59ea0d',
    'e4370607acd3448e9025311d61d85d19081bbac8',
    'cec754b643ef24a8f179a3a2740071318ebfdd15',
    '6d191a6ab0680502cc525551340e2a4c776a6e06',
    '3cb02b1db9dc9bb047cc0841674876a4ba1b5518',
]

for blob in blobs:
    result = subprocess.run(
        ['git', '-C', r'E:\ai\kimi\gvim_IDE\nvim', 'cat-file', 'blob', blob],
        capture_output=True
    )
    try:
        content = result.stdout.decode('utf-8')
    except UnicodeDecodeError:
        continue
    lines = content.splitlines()
    has_show = 'def show_window(payload):' in content
    has_build_ui = 'def build_ui(state, render_window, on_close_callback):' in content
    has_tk = 'tk.Tk()' in content
    if has_show and has_build_ui and has_tk:
        print(f'{blob}: {len(lines)} lines - MATCH')
    elif has_show or has_build_ui or has_tk:
        print(f'{blob}: {len(lines)} lines - partial')
