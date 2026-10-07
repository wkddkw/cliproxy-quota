"""Generate documentation illustrations (sample data, no real credentials)."""
from html import escape
import base64
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
output = root / 'docs/images'
output.mkdir(parents=True, exist_ok=True)
parts = []

def rect(x, y, w, h, color, radius=0, stroke=None):
    parts.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{radius}" fill="{color}"' + (f' stroke="{stroke}"' if stroke else '') + '/>')

def text(x, y, value, size=15, color='#163c30', weight=400):
    parts.append(f'<text x="{x}" y="{y}" font-size="{size}" fill="{color}" font-weight="{weight}">{escape(value)}</text>')

def circle(x, y, symbol):
    parts.append(f'<circle cx="{x}" cy="{y}" r="18" fill="#d9e8df"/>')
    name = {'G': 'gpt', '✳': 'claude', '𝕏': 'grok'}.get(symbol)
    if name:
        encoded = base64.b64encode((root / f'assets/providers/{name}.png').read_bytes()).decode()
        parts.append(f'<image x="{x-12}" y="{y-12}" width="24" height="24" href="data:image/png;base64,{encoded}"/>')
    else:
        parts.append(f'<text x="{x}" y="{y + 7}" text-anchor="middle" font-size="22" fill="#163c30" font-weight="600">{escape(symbol)}</text>')

def phone(x, title, index):
    rect(x, 122, 298, 575, '#163c30', 34)
    rect(x + 7, 129, 284, 561, '#f5f7f5', 28)
    rect(x + 107, 138, 84, 19, '#163c30', 10)
    text(x + 25, 152, '9:41', 10, weight=600)
    text(x + 24, 197, title, 16, weight=600)
    rect(x + 110, 675, 78, 4, '#163c30', 2)
    caption = {'01': '连接设置', '02': '供应商总览', '03': '认证文件明细'}[index]
    text(x, 735, f'{index}  {caption}', 17, weight=600)

parts.append('<svg xmlns="http://www.w3.org/2000/svg" width="1400" height="800" viewBox="0 0 1400 800">')
parts.append('<g font-family="Noto Sans CJK SC, PingFang SC, Microsoft YaHei, sans-serif">')
rect(0, 0, 1400, 800, '#edf3ef', 20)
text(45, 58, 'CLIProxy 限额', 30, weight=700)
text(45, 88, '主动查额度 · 定时刷新 · 百分比提醒 · 应用内更新', 16, '#536b60')
text(1110, 64, '界面示意 / 示例数据', 14, '#536b60')

x = 45
phone(x, '连接服务器', '01')
text(x + 24, 252, '你的服务，', 28, weight=700)
text(x + 24, 291, '随手可见。', 28, weight=700)
text(x + 24, 323, '连接已经运行的 CLIProxyAPI', 12, '#536b60')
for y, label, value in [(355, '服务器', '100.64.0.10'), (437, '管理密钥', '••••••••••••')]:
    rect(x + 24, y, 250, 60, '#ffffff', 14, '#b5c9bd')
    text(x + 36, y + 21, label, 11, '#536b60')
    text(x + 36, y + 44, value, 16)
rect(x + 24, 529, 250, 47, '#23846b', 24)
text(x + 107, 559, '保存并连接', 14, '#ffffff', 600)
text(x + 24, 615, '更多  ⌄', 14)
text(x + 24, 652, '端口与完整地址在「更多」中设置', 11, '#536b60')

x = 380
phone(x, '更新于 10-07 09:41', '02')
text(x + 24, 247, '剩余，心中有数。', 24, weight=700)
text(x + 24, 276, '按供应商查看 · 多账号取最低剩余', 11, '#536b60')
for i, (name, symbol, count, percent) in enumerate([('GPT', 'G', 2, 5), ('Claude', '✳', 3, 60), ('Grok', '𝕏', 1, 42), ('Other', 'O', 1, None)]):
    y = 299 + i * 86
    rect(x + 18, y, 262, 77, '#ffffff', 14)
    circle(x + 46, y + 29, symbol)
    text(x + 75, y + 25, name, 16, weight=600)
    text(x + 75, y + 44, f'{count} 个账号', 10, '#536b60')
    text(x + 209, y + 36, '—' if percent is None else f'{percent}%', 23, weight=700)
    rect(x + 26, y + 59, 245, 5, '#d9e8df', 3)
    if percent is not None:
        rect(x + 26, y + 59, max(3, 245 * percent / 100), 5, '#a94438' if percent <= 15 else '#23846b', 3)
    else:
        text(x + 76, y + 72, '暂不支持', 9, '#a94438')
text(x + 24, 660, '下拉刷新 · 点供应商查看账号', 11, '#536b60')

x = 715
phone(x, 'Grok', '03')
text(x + 24, 245, 'grok-account@example.invalid', 12, '#536b60')
rect(x + 18, 268, 262, 140, '#ffffff', 14)
text(x + 32, 296, '每周限额', 16, weight=600)
text(x + 32, 332, '该周期剩余 42%', 23, weight=600)
text(x + 32, 362, '周期结束 / 重置：10-08 17:00', 11, '#536b60')
text(x + 32, 389, '仅显示接口实际提供的额度', 11, '#536b60')
rect(x + 18, 429, 262, 186, '#ffffff', 14)
text(x + 32, 459, '月度美元额度', 16, weight=600)
text(x + 32, 486, '周期：10-01 至 11-01', 11, '#536b60')
text(x + 32, 516, '总额度', 11, '#536b60')
text(x + 165, 516, '$150.00', 18, weight=600)
text(x + 32, 547, '已用', 11, '#536b60')
text(x + 165, 547, '$45.00', 18, weight=600)
text(x + 32, 578, '剩余', 11, '#536b60')
text(x + 165, 578, '$105.00', 18, weight=600)
text(x + 24, 647, '不同周期分开展示；绝对额度按接口返回', 10, '#536b60')

x = 1050
rect(x, 122, 298, 575, '#163c30', 34)
rect(x + 7, 129, 284, 561, '#f5f7f5', 28)
rect(x + 107, 138, 84, 19, '#163c30', 10)
text(x + 25, 152, '9:41', 10, weight=600)
text(x + 24, 197, '设置', 16, weight=600)
rect(x + 18, 220, 262, 168, '#ffffff', 14)
text(x + 32, 248, '限额通知', 15, weight=600)
text(x + 246, 248, '？', 16, '#536b60')
text(x + 32, 280, '定时刷新', 13)
rect(x + 214, 265, 46, 23, '#23846b', 12)
parts.append(f'<circle cx="{x + 248}" cy="276.5" r="8" fill="white"/>')
for offset, label, selected in [(32, '15 分钟', True), (109, '30 分钟', False), (186, '60 分钟', False)]:
    rect(x + offset, 299, 72, 29, '#d9e8df' if selected else '#f5f7f5', 15)
    text(x + offset + 9, 319, label, 11, weight=600 if selected else 400)
text(x + 32, 352, '每下降 5 个百分点提醒', 12)
text(x + 32, 376, '最近后台检查  09:41', 10, '#536b60')
rect(x + 18, 403, 262, 99, '#ffffff', 14)
text(x + 32, 432, '应用更新 · v0.1.8', 15, weight=600)
text(x + 246, 432, '？', 16, '#536b60')
rect(x + 32, 446, 104, 35, '#d9e8df', 18)
text(x + 54, 469, '检查更新', 12, weight=600)
text(x + 24, 531, '达到阈值时的通知示意', 11, '#536b60')
rect(x + 18, 545, 262, 88, '#dfeae2', 18)
text(x + 32, 569, 'GPT 限额消耗提醒', 13, weight=600)
text(x + 32, 595, '剩余 35%', 19, weight=700)
text(x + 32, 619, '较上次基准下降 5 个百分点', 10, '#536b60')
rect(x + 110, 675, 78, 4, '#163c30', 2)
text(x, 735, '04  刷新 / 通知 / 应用更新', 17, weight=600)
parts.append('</g></svg>')
(output / 'app-preview.svg').write_text('\n'.join(parts))
subprocess.run(['rsvg-convert', '-w', '2100', '-o', str(output / 'app-preview-v0.1.8.png'), str(output / 'app-preview.svg')], check=True)

flow = '''<svg xmlns="http://www.w3.org/2000/svg" width="1400" height="240" viewBox="0 0 1400 240">
<defs><marker id="arrow" markerWidth="8" markerHeight="8" refX="7" refY="4" orient="auto"><path d="M0,0 L8,4 L0,8" fill="#23846b"/></marker></defs>
<rect width="1400" height="240" rx="20" fill="#edf3ef"/>
<g font-family="Noto Sans CJK SC, PingFang SC, Microsoft YaHei, sans-serif" fill="#163c30" text-anchor="middle">
<rect x="35" y="50" width="280" height="130" rx="20" fill="white"/><text x="175" y="93" font-size="22" font-weight="600">你的 CLIProxyAPI</text><text x="175" y="125" font-size="15">v8 优先 · 404 回退 v0</text><text x="175" y="151" font-size="13" fill="#536b60">只读主动查询 / 已启用的限额插件</text>
<rect x="385" y="50" width="280" height="130" rx="20" fill="white"/><text x="525" y="93" font-size="22" font-weight="600">手机 App</text><text x="525" y="125" font-size="15">刷新 · 归并 · 取最低剩余</text><text x="525" y="151" font-size="13" fill="#536b60">管理密钥保存在系统安全存储</text>
<rect x="735" y="50" width="280" height="130" rx="20" fill="white"/><text x="875" y="93" font-size="22" font-weight="600">本机汇总缓存</text><text x="875" y="125" font-size="15">供应商 · 账号数 · 百分比</text><text x="875" y="151" font-size="13" fill="#536b60">不含密钥、邮箱或认证文件名</text>
<rect x="1085" y="50" width="280" height="130" rx="20" fill="#23846b"/><text x="1225" y="93" font-size="22" font-weight="600" fill="white">Android 通知</text><text x="1225" y="125" font-size="15" fill="white">阈值提醒 · 可隐藏内容</text><text x="1225" y="151" font-size="13" fill="#d9e8df">后台检查 · 系统调度</text>
<g stroke="#23846b" stroke-width="3" marker-end="url(#arrow)"><path d="M325 115 H375"/><path d="M675 115 H725"/><path d="M1025 115 H1075"/></g>
<text x="700" y="218" font-size="13" fill="#536b60">额度查询通过自己的 CLIProxyAPI；应用更新另外从项目 GitHub 发布页下载。</text>
</g></svg>'''
(output / 'data-flow.svg').write_text(flow)
subprocess.run(['rsvg-convert', '-w', '2100', '-o', str(output / 'data-flow.png'), str(output / 'data-flow.svg')], check=True)
