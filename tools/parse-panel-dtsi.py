import re, sys

src = '/mnt/c/Users/L1872/Documents/nuwa ubt/public/nuwa/resources/panel-m2-38-0c-0a.dtsi'
txt = open(src).read()

# 抓第一个 on-command 块
m = re.search(r'qcom,mdss-dsi-on-command\s*=\s*\[(.*?)\];', txt, re.S)
if not m:
    print('no block'); sys.exit(1)
body = m.group(1)
# 去掉注释
body = re.sub(r'/\*.*?\*/', '', body, flags=re.S)
# 提取所有十六进制字节
toks = re.findall(r'\b[0-9A-Fa-f]{2}\b', body)
data = [int(t, 16) for t in toks]
print('total bytes:', len(data))

# 按 Qualcomm 格式切分：type,last,vc,ack,wait,len_hi,len_lo,payload
i = 0
cmds = []
while i + 7 <= len(data):
    dtype = data[i]
    ln = (data[i+5] << 8) | data[i+6]
    payload = data[i+7:i+7+ln]
    if len(payload) < ln:
        print('truncated at', i, 'want', ln, 'got', len(payload)); break
    cmds.append((dtype, payload))
    i += 7 + ln
print('parsed commands:', len(cmds))
for k, (dt, pl) in enumerate(cmds[:6]):
    hexs = ' '.join('0x%02x,' % b for b in pl[:10])
    print('  [%d] type=0x%02x len=%d  %s%s' % (k, dt, len(pl), hexs, ' ...' if len(pl) > 10 else ''))

# 生成 C 片段示例
if cmds:
    dt, pl = cmds[0]
    print()
    print('/* C 示例（第一段，共 %d 字节 payload） */' % len(pl))
    print('    mipi_dsi_dcs_write_seq(dsi, 0x%02x, %s);' % (pl[0], ', '.join('0x%02x' % b for b in pl[1:6])) + ' /* ... */')