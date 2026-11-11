import sys, xml.etree.ElementTree as ET, collections
tree = ET.parse(sys.argv[1]); root = tree.getroot()
ids = {}
def resolve(e):
    r = e.get('ref')
    if r is not None: return ids[r]
    i = e.get('id')
    if i is not None: ids[i] = e
    return e
incl = collections.Counter(); leaf = collections.Counter(); total = 0; main_total = 0
for row in root.iter('row'):
    th = row.find('thread'); w = row.find('weight')
    bt = row.find('tagged-backtrace')
    if bt is None: bt = row.find('backtrace')
    if th is None or bt is None: continue
    th = resolve(th); bt = resolve(bt)
    if w is not None: w = resolve(w)
    ms = int(w.text)/1e6 if w is not None and w.text else 1.0
    total += ms
    frames = [resolve(f) for f in bt.iter('frame')]
    if 'Main Thread' not in (th.get('fmt') or ''): continue
    main_total += ms
    names = [f.get('name') or '?' for f in frames]
    if names: leaf[names[0]] += ms
    for n in set(names): incl[n] += ms
print(f"total {total:.0f} ms, main thread {main_total:.0f} ms")
filt = sys.argv[2] if len(sys.argv) > 2 else ''
print("-- inclusive (main)")
for n, v in incl.most_common(400):
    if filt in n and len(n) < 400: print(f"{v:8.0f}  {n[:150]}")
