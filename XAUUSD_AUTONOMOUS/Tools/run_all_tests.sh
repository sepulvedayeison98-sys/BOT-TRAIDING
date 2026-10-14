#!/usr/bin/env bash
# Ejecuta toda la batería: compila todos los .mq5 del proyecto, corre los scripts
# Tests/Validation/Test_*.mq5 en MT5 (Wine) y las pruebas de Python.
set -u
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR" || exit 2
status=0
mapfile -t ALL < <(find Experts Tests -name '*.mq5' | sort)
mapfile -t TESTS < <(find Tests/Validation -name 'Test_*.mq5' | sort)
echo "### Compilación (${#ALL[@]} archivos)"
Tools/compile.sh "${ALL[@]}" || status=1
echo "### Pruebas MQL5 (${#TESTS[@]} scripts)"
TEST_TIMEOUT_SEC="${TEST_TIMEOUT_SEC:-400}" Tools/run_tests.sh "${TESTS[@]}" | grep -E "^(RESULT|FAIL|== .*SIN REPORTE)" || true
[ "${PIPESTATUS[0]}" -eq 0 ] || status=1
echo "### Pruebas Python"
python3 -m unittest discover -s Tools/tests 2>&1 | tail -3
[ "${PIPESTATUS[0]}" -eq 0 ] || status=1
echo "### Pruebas del servidor del dashboard web"
python3 -m unittest discover -s WebDashboard/tests 2>&1 | tail -3
[ "${PIPESTATUS[0]}" -eq 0 ] || status=1
echo "### Estado global: $([ $status -eq 0 ] && echo OK || echo FALLOS)"
exit $status
