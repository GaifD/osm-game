#!/usr/bin/env python3
"""Скачивает данные Украины из OpenStreetMap (Overpass API) и пишет
компактные JSON для игры.

Запуск:  python tools/fetch_osm.py <папка_вывода>
Пишет:   oblasts.json, rivers.json, cities.json, grid.json, ok
Если какой-то запрос не удался — этот файл просто не пишется,
и игра использует запасной из assets/data.

Только стандартная библиотека Python — ничего ставить не нужно.
"""
import json
import math
import os
import sys
import time
import urllib.parse
import urllib.request

MIRRORS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
    "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
]
AREA = 'area["ISO3166-1"="UA"]["admin_level"="2"]->.ua;'
UA = "osm-game-builder/0.1 (+https://github.com/GaifD/osm-game)"
KLON = math.cos(math.radians(48.5))  # масштаб долготы для Украины
BBOX = (21.9, 44.2, 40.4, 52.5)  # lon_min, lat_min, lon_max, lat_max


# ---------------------------------------------------------------- сеть
def overpass(body, timeout=900):
    query = f"[out:json][timeout:{timeout}];{AREA}{body}"
    data = urllib.parse.urlencode({"data": query}).encode()
    last = None
    for attempt in range(2):
        for url in MIRRORS:
            try:
                req = urllib.request.Request(url, data=data, headers={"User-Agent": UA})
                with urllib.request.urlopen(req, timeout=timeout + 120) as r:
                    js = json.loads(r.read().decode("utf-8"))
                remark = js.get("remark") or ""
                if "error" in remark.lower() or "timed out" in remark.lower():
                    raise RuntimeError(remark)
                els = js.get("elements", [])
                print(f"    ok {url}: {len(els)} элементов", flush=True)
                return els
            except Exception as e:  # noqa: BLE001
                print(f"    сбой {url}: {e}", flush=True)
                last = e
                time.sleep(10)
    raise RuntimeError(f"все зеркала не ответили: {last}")


# ---------------------------------------------------------------- геометрия
def km(a, b):
    """Расстояние в км между (lon, lat)."""
    dx = (a[0] - b[0]) * 111.32 * math.cos(math.radians((a[1] + b[1]) / 2))
    dy = (a[1] - b[1]) * 110.57
    return math.hypot(dx, dy)


def path_km(pts):
    return sum(km(pts[i], pts[i + 1]) for i in range(len(pts) - 1))


def simplify(pts, tol):
    """Дуглас–Пекер, tol в градусах широты."""
    n = len(pts)
    if n < 3:
        return pts
    keep = [False] * n
    keep[0] = keep[-1] = True
    stack = [(0, n - 1)]
    while stack:
        a, b = stack.pop()
        if b <= a + 1:
            continue
        ax, ay = pts[a][0] * KLON, pts[a][1]
        bx, by = pts[b][0] * KLON, pts[b][1]
        dx, dy = bx - ax, by - ay
        L = dx * dx + dy * dy
        best, bi = -1.0, -1
        for i in range(a + 1, b):
            px, py = pts[i][0] * KLON, pts[i][1]
            if L == 0:
                d = math.hypot(px - ax, py - ay)
            else:
                t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / L))
                d = math.hypot(px - ax - t * dx, py - ay - t * dy)
            if d > best:
                best, bi = d, i
        if best > tol:
            keep[bi] = True
            stack.append((a, bi))
            stack.append((bi, b))
    return [p for p, k in zip(pts, keep) if k]


def _key(p):
    return (round(p[0], 6), round(p[1], 6))


def stitch(segs):
    """Склеивает куски линий (ways) в длинные линии/кольца по общим концам."""
    segs = [list(s) for s in segs if len(s) >= 2]
    ends = {}

    def add(i):
        ends.setdefault(_key(segs[i][0]), set()).add(i)
        ends.setdefault(_key(segs[i][-1]), set()).add(i)

    def rem(i):
        for k in (_key(segs[i][0]), _key(segs[i][-1])):
            s = ends.get(k)
            if s:
                s.discard(i)

    for i in range(len(segs)):
        add(i)
    used = [False] * len(segs)
    out = []
    for i in range(len(segs)):
        if used[i]:
            continue
        used[i] = True
        rem(i)
        cur = segs[i]
        for side in (1, 0):  # 1 = хвост, 0 = голова
            while True:
                if len(cur) > 3 and _key(cur[0]) == _key(cur[-1]):
                    break
                p = _key(cur[-1] if side else cur[0])
                cand = [j for j in ends.get(p, ()) if not used[j]]
                if not cand:
                    break
                j = cand[0]
                used[j] = True
                rem(j)
                s = segs[j]
                if side:
                    cur = cur + (s[1:] if _key(s[0]) == p else s[::-1][1:])
                else:
                    cur = (s[:-1] if _key(s[-1]) == p else s[::-1][:-1]) + cur
        out.append(cur)
    return out


def flat(pts, nd=4):
    r = []
    for p in pts:
        r.append(round(p[0], nd))
        r.append(round(p[1], nd))
    return r


def in_bbox(p, pad=0.0):
    return BBOX[0] - pad <= p[0] <= BBOX[2] + pad and BBOX[1] - pad <= p[1] <= BBOX[3] + pad


def clip_to_bbox(line):
    """Режет линию на куски, лежащие внутри bbox Украины."""
    parts, cur = [], []
    for p in line:
        if in_bbox(p, 0.3):
            cur.append(p)
        else:
            if len(cur) >= 2:
                parts.append(cur)
            cur = []
    if len(cur) >= 2:
        parts.append(cur)
    return parts


def name_of(tags):
    return tags.get("name:ru") or tags.get("name") or tags.get("name:uk") or ""


def geom_pts(g):
    return [(p["lon"], p["lat"]) for p in g if p]


# ---------------------------------------------------------------- области
def build_oblasts(els):
    out = []
    for e in els:
        if e.get("type") != "relation":
            continue
        tags = e.get("tags", {})
        segs = [geom_pts(m["geometry"]) for m in e.get("members", [])
                if m.get("type") == "way" and m.get("role", "outer") in ("outer", "")
                and m.get("geometry")]
        rings = []
        for r in stitch(segs):
            if len(r) < 4:
                continue
            s = simplify(r, 0.006)
            if len(s) >= 4:
                rings.append(flat(s, 3))
        if rings:
            out.append({"n": name_of(tags), "iso": tags.get("ISO3166-2", ""), "rings": rings})
    out.sort(key=lambda o: o["iso"])
    return out


# ---------------------------------------------------------------- реки
RIVERS = ("Дніпро|Дністер|Десна|Південний Буг|Сіверський Донець|Прип.ять|Дунай|"
          "Інгулець|Ворскла|Сула|Псел|Рось|Тетерів|Горинь|Случ|Стир|Західний Буг|"
          "Тиса|Прут|Самара|Оріль|Інгул|Тясмин|Удай|Синюха|Сейм|Ірпінь|Уж|Конка|Кальміус")


def build_rivers(els):
    out = []
    for e in els:
        tags = e.get("tags", {})
        if e.get("type") == "relation":
            segs = [geom_pts(m["geometry"]) for m in e.get("members", [])
                    if m.get("type") == "way" and m.get("geometry")
                    and m.get("role", "") in ("", "main_stream", "main")]
        elif e.get("type") == "way" and e.get("geometry"):
            segs = [geom_pts(e["geometry"])]
        else:
            continue
        for line in stitch(segs):
            for part in clip_to_bbox(line):
                s = simplify(part, 0.003)
                if len(s) >= 2 and path_km(s) > 3:
                    out.append({"n": name_of(tags), "pts": flat(s, 3)})
    return out


# ---------------------------------------------------------------- города
def parse_pop(v):
    if not v:
        return 0
    digits = "".join(ch for ch in str(v).split(";")[0] if ch.isdigit())
    try:
        return int(digits)
    except ValueError:
        return 0


def build_cities(els):
    out = []
    seen = set()
    for e in els:
        if e.get("type") != "node":
            continue
        tags = e.get("tags", {})
        pop = parse_pop(tags.get("population"))
        place = tags.get("place")
        if pop == 0:
            pop = 50000 if place == "city" else 0
        if pop < 15000:
            continue
        n = name_of(tags)
        k = (n, round(e["lat"], 2), round(e["lon"], 2))
        if not n or k in seen:
            continue
        seen.add(k)
        out.append({"n": n, "pop": pop, "lat": round(e["lat"], 4), "lon": round(e["lon"], 4)})
    out.sort(key=lambda c: -c["pop"])
    return out


# ---------------------------------------------------------------- энергосеть
def kv_classes(v):
    res = set()
    for part in str(v or "").replace(",", ";").split(";"):
        part = part.strip()
        if not part.isdigit():
            continue
        x = int(part)
        if x >= 700000:
            res.add(750)
        elif 380000 <= x <= 420000:
            res.add(400)
        elif 300000 <= x <= 350000:
            res.add(330)
        elif 200000 <= x <= 240000:
            res.add(220)
        elif 100000 <= x <= 160000:
            res.add(110)
        elif 30000 <= x <= 40000:
            res.add(35)
    return res


def parse_mw(v):
    if not v:
        return 0.0
    s = str(v).lower().replace(" ", "").replace("\u00a0", "").replace(",", ".").strip()
    num = ""
    for ch in s:
        if ch.isdigit() or ch == ".":
            num += ch
        elif num:
            break
    try:
        x = float(num)
    except ValueError:
        return 0.0
    if "gw" in s:
        x *= 1000
    elif "kw" in s:
        x /= 1000
    elif "w" in s and "mw" not in s:
        x /= 1e6
    return x


def plant_type(tags):
    src = (tags.get("plant:source") or tags.get("generator:source") or "").lower()
    method = (tags.get("plant:method") or "").lower()
    n = (tags.get("name") or "") + " " + (tags.get("name:ru") or "")
    nu = n.upper()
    if "nuclear" in src:
        return "aes"
    if "hydro" in src or "water" in src:
        if "pumped" in method or "ГАЕС" in nu or "ГАЭС" in nu:
            return "gaes"
        return "ges"
    if "solar" in src:
        return "ses"
    if "wind" in src:
        return "ves"
    if "coal" in src:
        return "tes_coal"
    if "gas" in src or "oil" in src or "diesel" in src or "biomass" in src or "waste" in src:
        if "ТЕЦ" in nu or "ТЭЦ" in nu:
            return "tec"
        return "tes_gas"
    if "ТЕЦ" in nu or "ТЭЦ" in nu:
        return "tec"
    if "ТЕС" in nu or "ТЭС" in nu:
        return "tes_coal"
    return ""


DEFAULT_MW = {"aes": 2000, "tes_coal": 800, "tes_gas": 0, "tec": 80, "ges": 30,
              "gaes": 300, "ses": 0, "ves": 0}
MIN_MW = {"aes": 1, "tes_coal": 20, "tes_gas": 20, "tec": 20, "ges": 10, "gaes": 10,
          "ses": 20, "ves": 20}


STATS = {}


def retired(tags):
    """Закрытые / недостроенные станции (например, ЧАЭС)."""
    for k in tags:
        if k.split(":")[0] in ("disused", "abandoned", "demolished", "construction", "proposed", "was", "razed"):
            return True
    if tags.get("end_date") or tags.get("power") != "plant":
        return True
    n = (tags.get("name", "") + " " + tags.get("name:ru", "") + " " + tags.get("name:en", "")).lower()
    return any(w in n for w in ("чорнобил", "чернобыл", "chernobyl", "chornobyl"))


def center(e):
    if "lat" in e and "lon" in e:
        return (e["lon"], e["lat"])
    c = e.get("center")
    if c:
        return (c["lon"], c["lat"])
    return None


class Grid:
    """Пространственный индекс для поиска ближайшего узла."""

    def __init__(self, cell=0.05):
        self.cell = cell
        self.b = {}

    def _c(self, p):
        return (int(math.floor(p[0] / self.cell)), int(math.floor(p[1] / self.cell)))

    def add(self, p, item):
        self.b.setdefault(self._c(p), []).append((p, item))

    def nearest(self, p, max_km, pred=None):
        cx, cy = self._c(p)
        r = int(math.ceil(max_km / (self.cell * 70))) + 1
        best, bd = None, max_km
        for x in range(cx - r, cx + r + 1):
            for y in range(cy - r, cy + r + 1):
                for q, it in self.b.get((x, y), ()):
                    if pred and not pred(it):
                        continue
                    d = km(p, q)
                    if d <= bd:
                        best, bd = it, d
        return best, bd


def build_grid(line_els, sub_els, plant_els):
    STATS.update({"lines_raw": len(line_els), "subs_raw": len(sub_els), "plants_raw": len(plant_els)})
    STATS["subs_no_pos"] = sum(1 for e in sub_els if not center(e))
    STATS["subs_types"] = {t: sum(1 for e in sub_els if e.get("type") == t) for t in ("node", "way", "relation")}
    STATS["sub_sample"] = sub_els[:2]
    nodes = {}
    order = []

    def add_node(nid, **kw):
        nodes[nid] = kw
        order.append(nid)

    subidx = Grid()
    for i, e in enumerate(sub_els):
        p = center(e)
        if not p:
            continue
        tags = e.get("tags", {})
        kv = kv_classes(tags.get("voltage"))
        if not kv:
            continue
        nid = f"s{i}"
        add_node(nid, t="sub", n=name_of(tags), p=p, kv=set(kv))
        subidx.add(p, nid)

    plantidx = Grid()
    for i, e in enumerate(plant_els):
        p = center(e)
        if not p:
            continue
        tags = e.get("tags", {})
        pt = plant_type(tags)
        if not pt or retired(tags):
            STATS["plants_skipped"] = STATS.get("plants_skipped", 0) + 1
            continue
        mw = parse_mw(tags.get("plant:output:electricity"))
        if mw <= 0:
            mw = DEFAULT_MW.get(pt, 0)
        if mw < MIN_MW.get(pt, 20):
            continue
        nid = f"p{i}"
        add_node(nid, t="plant", n=name_of(tags), p=p, kv=set(), pt=pt, mw=round(mw, 1))
        plantidx.add(p, nid)

    jidx = Grid(0.02)
    jcount = [0]

    def snap(p, kv):
        nid, _ = subidx.nearest(p, 1.5)
        if nid:
            return nid
        nid, _ = plantidx.nearest(p, 2.5)
        if nid:
            return nid
        nid, _ = jidx.nearest(p, 0.4)
        if nid:
            return nid
        nid = f"j{jcount[0]}"
        jcount[0] += 1
        add_node(nid, t="j", n="", p=p, kv=set())
        jidx.add(p, nid)
        return nid

    edges = []
    for e in line_els:
        if e.get("type") != "way" or not e.get("geometry"):
            continue
        tags = e.get("tags", {})
        kvs = kv_classes(tags.get("voltage")) - {110, 35}
        if not kvs:
            continue
        kv = max(kvs)
        pts = geom_pts(e["geometry"])
        if len(pts) < 2:
            continue
        a = snap(pts[0], kv)
        b = snap(pts[-1], kv)
        if a == b:
            continue
        nodes[a]["kv"].add(kv)
        nodes[b]["kv"].add(kv)
        try:
            circ = max(1, int(str(tags.get("circuits", "1")).split(";")[0]))
        except ValueError:
            circ = 1
        edges.append({"a": a, "b": b, "kv": kv, "c": min(circ, 4), "pts": pts, "v": 0})

    # склеиваем цепочки через промежуточные узлы-стыки (2 линии одного напряжения)
    changed = True
    while changed:
        changed = False
        adj = {}
        for i, ed in enumerate(edges):
            if ed is None:
                continue
            adj.setdefault(ed["a"], []).append(i)
            adj.setdefault(ed["b"], []).append(i)
        for nid, lst in adj.items():
            if nodes[nid]["t"] != "j" or len(lst) != 2:
                continue
            i1, i2 = lst
            e1, e2 = edges[i1], edges[i2]
            if e1 is None or e2 is None or i1 == i2 or e1["kv"] != e2["kv"]:
                continue
            p1 = e1["pts"] if e1["b"] == nid else e1["pts"][::-1]
            o1 = e1["a"] if e1["b"] == nid else e1["b"]
            p2 = e2["pts"] if e2["a"] == nid else e2["pts"][::-1]
            o2 = e2["b"] if e2["a"] == nid else e2["a"]
            if o1 == o2:
                continue
            edges[i1] = {"a": o1, "b": o2, "kv": e1["kv"], "c": min(e1["c"], e2["c"]),
                         "pts": p1 + p2[1:], "v": 0}
            edges[i2] = None
            nodes[nid]["dead"] = True
            changed = True
            break  # пересобираем смежность
    edges = [e for e in edges if e is not None]

    # станции без линий — виртуальное подключение к ближайшей подстанции
    connected = set()
    for ed in edges:
        connected.add(ed["a"])
        connected.add(ed["b"])
    for nid in list(order):
        nd = nodes[nid]
        if nd["t"] != "plant" or nid in connected:
            continue
        sid, d = subidx.nearest(nd["p"], 25)
        if not sid:
            continue
        kv = max(nodes[sid]["kv"])
        nd["kv"].add(kv)
        edges.append({"a": nid, "b": sid, "kv": kv, "c": 1, "pts": [nd["p"], nodes[sid]["p"]], "v": 1})

    # 330/220 кВ подстанции почти всегда имеют сторону 110 кВ
    for nd in nodes.values():
        if nd["t"] == "sub" and (330 in nd["kv"] or 220 in nd["kv"]):
            nd["kv"].add(110)

    used = set()
    out_edges = []
    for ed in edges:
        pts = simplify(ed["pts"], 0.002)
        out_edges.append({"a": ed["a"], "b": ed["b"], "kv": ed["kv"], "c": ed["c"],
                          "v": ed["v"], "len": round(path_km(ed["pts"]), 1), "pts": flat(pts, 4)})
        used.add(ed["a"])
        used.add(ed["b"])
    out_nodes = []
    for nid in order:
        nd = nodes[nid]
        if nd.get("dead"):
            continue
        if nd["t"] == "j" and nid not in used:
            continue
        o = {"id": nid, "t": nd["t"], "n": nd["n"], "lon": round(nd["p"][0], 4),
             "lat": round(nd["p"][1], 4), "kv": sorted(nd["kv"], reverse=True)}
        if nd["t"] == "plant":
            o["pt"] = nd["pt"]
            o["mw"] = nd["mw"]
        out_nodes.append(o)
    return {"nodes": out_nodes, "edges": out_edges}


# ---------------------------------------------------------------- дороги / ЖД (граф)
def build_graph(els, cls_of, tol=0.002):
    """Строит граф из ways: узлы — перекрёстки/концы, рёбра — участки между ними.
    cls_of(tags) -> int класс или None (пропустить)."""
    ways = []
    use = {}
    for e in els:
        if e.get("type") != "way" or not e.get("geometry") or not e.get("nodes"):
            continue
        c = cls_of(e.get("tags", {}))
        if c is None:
            continue
        ids = e["nodes"]
        pts = geom_pts(e["geometry"])
        if len(ids) != len(pts) or len(ids) < 2:
            continue
        ways.append((ids, pts, c))
        for nid in ids:
            use[nid] = use.get(nid, 0) + 1
    # режем ways на рёбра по перекрёсткам
    coord = {}
    edges = []  # [a, b, cls, pts]
    for ids, pts, c in ways:
        start = 0
        for k in range(1, len(ids)):
            if k == len(ids) - 1 or use.get(ids[k], 0) > 1:
                a, b = ids[start], ids[k]
                if a != b:
                    coord[a] = pts[start]
                    coord[b] = pts[k]
                    edges.append([a, b, c, pts[start:k + 1]])
                start = k
    # склеиваем цепочки через узлы степени 2 одного класса
    adj = {}
    for i, e in enumerate(edges):
        adj.setdefault(e[0], []).append(i)
        adj.setdefault(e[1], []).append(i)

    def interior(v):
        lst = adj.get(v, [])
        return len(lst) == 2 and lst[0] != lst[1] and edges[lst[0]][2] == edges[lst[1]][2]

    seen = [False] * len(edges)
    merged = []

    def walk(start_node, ei):
        cur = start_node
        pts = []
        c = edges[ei][2]
        while True:
            seen[ei] = True
            e = edges[ei]
            seg = e[3] if e[0] == cur else e[3][::-1]
            nxt = e[1] if e[0] == cur else e[0]
            pts = seg if not pts else pts + seg[1:]
            cur = nxt
            if not interior(cur):
                break
            lst = adj[cur]
            ei2 = lst[0] if lst[1] == ei else lst[1]
            if seen[ei2]:
                break
            ei = ei2
        return [start_node, cur, c, pts]

    for v in list(adj.keys()):
        if interior(v):
            continue
        for ei in adj[v]:
            if not seen[ei]:
                merged.append(walk(v, ei))
    for ei in range(len(edges)):
        if not seen[ei]:
            merged.append(walk(edges[ei][0], ei))

    idx = {}
    nodes_flat = []
    out_edges = []
    for a, b, c, pts in merged:
        if a == b and len(pts) < 4:
            continue
        for v in (a, b):
            if v not in idx:
                idx[v] = len(idx)
                p = coord.get(v, pts[0] if v == a else pts[-1])
                nodes_flat += [round(p[0], 4), round(p[1], 4)]
        sp = simplify(pts, tol)
        out_edges.append([idx[a], idx[b], c, round(path_km(pts), 2), flat(sp[1:-1], 4)])
    return {"nodes": nodes_flat, "edges": out_edges}


ROAD_CLS = {"motorway": 0, "motorway_link": 0, "trunk": 1, "trunk_link": 1, "primary": 2, "primary_link": 2}


def road_cls(tags):
    return ROAD_CLS.get(tags.get("highway"))


def rail_cls(tags):
    if tags.get("railway") != "rail" or tags.get("service"):
        return None
    if tags.get("usage") in ("industrial", "military", "tourism", "test"):
        return None
    return 0 if tags.get("electrified") in ("contact_line", "rail", "yes") else 1


# ---------------------------------------------------------------- main
def save(out_dir, name, obj):
    path = os.path.join(out_dir, name)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, separators=(",", ":"))
    print(f"  -> {name}: {os.path.getsize(path) // 1024} КБ", flush=True)


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "osm_out"
    force = "--force" in sys.argv
    os.makedirs(out_dir, exist_ok=True)
    good = 0
    fresh = 0

    steps = [
        ("oblasts.json", "области",
         lambda: build_oblasts(overpass(
             'rel["boundary"="administrative"]["admin_level"="4"]["ISO3166-2"~"^UA-"];out geom;')),
         lambda r: len(r) >= 20),
        ("rivers.json", "реки",
         lambda: build_rivers(overpass(
             f'rel["waterway"="river"]["name"~"^({RIVERS})$"](area.ua);out geom;')),
         lambda r: len(r) >= 5),
        ("cities.json", "города",
         lambda: build_cities(overpass('node["place"~"^(city|town)$"](area.ua);out;')),
         lambda r: len(r) >= 50),
        ("grid.json", "энергосеть",
         lambda: build_grid(
             overpass('way["power"="line"]["voltage"~"(750000|400000|330000|220000)"](area.ua);out geom;'),
             overpass('nwr["power"="substation"]["voltage"~"(750000|400000|330000|220000)"](area.ua);out center;'),
             overpass('nwr["power"="plant"](area.ua);out center;')),
         lambda r: len(r["edges"]) >= 30),
        ("roads.json", "дороги",
         lambda: build_graph(overpass(
             'way["highway"~"^(motorway|motorway_link|trunk|trunk_link|primary|primary_link)$"](area.ua);out geom;'),
             road_cls, 0.002),
         lambda r: len(r["edges"]) >= 500),
        ("railways.json", "железные дороги",
         lambda: build_graph(overpass('way["railway"="rail"][!"service"](area.ua);out geom;'), rail_cls, 0.002),
         lambda r: len(r["edges"]) >= 200),
    ]
    for fname, label, fn, check in steps:
        if not force and os.path.exists(os.path.join(out_dir, fname)):
            print(f"== {label}: уже есть, пропускаю", flush=True)
            good += 1
            continue
        print(f"== {label}", flush=True)
        try:
            res = fn()
            if not check(res):
                print(f"  слишком мало данных для {label}, пропускаю", flush=True)
                continue
            save(out_dir, fname, res)
            good += 1
            fresh += 1
            open(os.path.join(out_dir, "new"), "w").close()
        except Exception as e:  # noqa: BLE001
            print(f"  ОШИБКА {label}: {e}", flush=True)
    STATS["good"] = good
    if fresh:
        save(out_dir, "stats.json", STATS)
    if good == len(steps):
        open(os.path.join(out_dir, "ok"), "w").close()
    print(f"готово: {good}/{len(steps)}, новых: {fresh}", flush=True)


if __name__ == "__main__":
    main()
