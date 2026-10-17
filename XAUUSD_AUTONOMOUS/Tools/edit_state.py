#!/usr/bin/env python3
"""Edita el archivo de estado del EA para pruebas de reinicio.

  edit_state.py ARCHIVO set CLAVE VALOR   -> cambia una clave y recalcula la suma (FNV-1a)
  edit_state.py ARCHIVO corrupt           -> altera el contenido SIN recalcular la suma

Usa el mismo formato y suma que Include/XAUUSD/StateStore.mqh (FNV-1a de 32 bits sobre
las unidades UTF-16 del cuerpo, líneas terminadas en "\\n").
"""
import sys


def fnv1a(text):
    h = 2166136261
    data = text.encode("utf-16-le")
    for i in range(0, len(data), 2):
        h ^= data[i] | (data[i + 1] << 8)
        h = (h * 16777619) & 0xFFFFFFFF
    return h


def main(argv):
    path, cmd = argv[1], argv[2]
    with open(path, encoding="utf-8") as fh:
        lines = [ln.rstrip("\r\n") for ln in fh]
    body_lines = [ln for ln in lines if ln and not ln.startswith("#checksum=")]
    if cmd == "set":
        key, value = argv[3], argv[4]
        found = False
        for i, ln in enumerate(body_lines):
            if ln.split("=", 1)[0] == key:
                body_lines[i] = f"{key}={value}"
                found = True
        if not found:
            body_lines.append(f"{key}={value}")
        body = "".join(ln + "\n" for ln in body_lines)
        out = body + f"#checksum={fnv1a(body):08X}\n"
    elif cmd == "corrupt":
        checksum = [ln for ln in lines if ln.startswith("#checksum=")]
        body_lines.append("ea.state=RUNNING_ALTERADO")
        out = "".join(ln + "\n" for ln in body_lines) + "".join(c + "\n" for c in checksum)
    else:
        raise SystemExit("comando desconocido")
    with open(path, "w", encoding="utf-8", newline="") as fh:
        fh.write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
