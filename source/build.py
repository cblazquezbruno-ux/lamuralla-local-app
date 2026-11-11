"""Monta index.html (un solo archivo con estilos, fuente e imágenes incrustadas) a partir de app.src.html.
Uso:  python3 source/build.py      (desde la raíz del repositorio)"""
import base64, os, re
H = os.path.dirname(os.path.abspath(__file__)); A = os.path.join(H, 'assets'); ROOT = os.path.dirname(H)
b = lambda f: base64.b64encode(open(os.path.join(A, f), 'rb').read()).decode()
t = open(os.path.join(H, 'app.src.html'), encoding='utf-8').read().replace('__BASECSS__', open(os.path.join(H, 'base.css'), encoding='utf-8').read())
t = t.replace('__SYMMASK__', 'data:image/png;base64,' + b('sym-mask.png'))
for k, f in [('__FONT__', 'archivo-latin.woff2'), ('__LOGO__', 'logo.png'), ('__ICON__', 'icon.png'), ('__BRUNO__', 'bruno.jpg'), ('__JESUS__', 'jesus.jpg'), ('__JP__', 'jose-pedro.jpg'),
             ('__FACHADA__', 'fachada.jpg'), ('__CJP__', 'card-jose-pedro.jpg'), ('__CBRUNO__', 'card-bruno.jpg'), ('__CJESUS__', 'card-jesus.jpg')]:
    t = t.replace(k, b(f))
left = set(re.findall(r'__[A-Z]+__', t))
assert not left, f'Quedan marcadores sin sustituir: {left}'
open(os.path.join(ROOT, 'index.html'), 'w', encoding='utf-8').write(t)
print('index.html generado:', round(len(t) / 1024), 'KB')
