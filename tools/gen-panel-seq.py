import re

src = '/mnt/c/Users/L1872/Documents/nuwa ubt/public/nuwa/resources/panel-m2-38-0c-0a.dtsi'
txt = open(src).read()
lines = txt.split(chr(10))

marks = []
for i, l in enumerate(lines):
    m = re.search(r'panel-framerate = <(\d+)>', l)
    if m:
        marks.append((i, int(m.group(1))))

out = []
out.append('/* SPDX-License-Identifier: GPL-2.0-only */')
out.append('/*')
out.append(' * Panel init sequences for samsung,amb673cp01-m2 (1440x3200, DSC 1.2)')
out.append(' *')
out.append(' * Generated from LineageOS android_kernel_xiaomi_sm8550-devicetrees')
out.append(' *   qcom/display/display/dsi-panel-m2-38-0c-0a-dsc-cmd.dtsi')
out.append(' * by public/nuwa/tools/gen-panel-seq.py — do not edit by hand.')
out.append(' *')
out.append(' * Each entry is a Qualcomm mdss-dsi-on-command blob:')
out.append(' *   type, last, vc, ack, wait, len_hi, len_lo, payload[len]')
out.append(' * Convert to mipi_dsi_dcs_write_seq() at probe time.')
out.append(' */')
out.append('#ifndef _PANEL_AMB673CP01_SEQ_H')
out.append('#define _PANEL_AMB673CP01_SEQ_H')
out.append('')

seen = {}
for k, (start, fr) in enumerate(marks):
    end = marks[k+1][0] if k+1 < len(marks) else len(lines)
    seg = chr(10).join(lines[start:end])
    m = re.search(r'qcom,mdss-dsi-on-command\s*=\s*\[(.*?)\];', seg, re.S)
    if not m:
        continue
    body = re.sub(r'/\*.*?\*/', '', m.group(1), flags=re.S)
    data = [int(t, 16) for t in re.findall(r'\b[0-9A-Fa-f]{2}\b', body)]
    idx = seen.get(fr, 0)
    seen[fr] = idx + 1
    name = 'seq_%dhz_%d' % (fr, idx)
    out.append('/* %d Hz, %d bytes */' % (fr, len(data)))
    out.append('static const unsigned char %s[] = {' % name)
    for j in range(0, len(data), 12):
        out.append('\t' + ' '.join('0x%02x,' % b for b in data[j:j+12]))
    out.append('};')
    out.append('')

out.append('#endif /* _PANEL_AMB673CP01_SEQ_H */')

dst = '/mnt/c/Users/L1872/Documents/nuwa ubt/public/nuwa/resources/panel-amb673cp01-sequences.h'
open(dst, 'w').write(chr(10).join(out))
print('wrote', dst)
print('lines:', len(out))
print('arrays:', sum(seen.values()))