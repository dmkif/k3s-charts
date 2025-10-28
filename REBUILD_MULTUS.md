# Multus Charts neu bauen

## Problem
Die alten Multus-Charts hatten ungültige Semver-Versionen mit `upv` (z.B. `4.0.201+upv4.0.2-build2024020802`).
Das `v` in der Upstream-Version ist ungültiges Semver und wird von Helm/charts-build-scripts abgelehnt.

## Lösung
Die package.yaml wurde gefixt mit einer expliziten `version` ohne das `v`.

## Was du tun musst

1. **Go installieren** (falls nicht vorhanden):
   ```bash
   sudo dnf install -y golang
   ```

2. **Multus Charts neu bauen**:
   ```bash
   cd /home/dmkif/git/k3s-charts
   PACKAGE=multus make charts
   ```

   Dies wird:
   - Die neuen Charts mit korrekter Version `4.0.201+up4.0.2-build2024020802` erstellen
   - Die `index.yaml` automatisch aktualisieren
   - Assets in `assets/multus/` erstellen

3. **Änderungen committen**:
   ```bash
   git add charts/ assets/ index.yaml
   git commit -m "chore: Rebuild multus charts with valid semver"
   git push
   ```

4. **Diese Datei löschen** (nicht mehr benötigt):
   ```bash
   git rm REBUILD_MULTUS.md
   git commit -m "chore: Remove rebuild instructions"
   git push
   ```

## Nach dem Rebuild

Der CI-Workflow sollte dann ohne Semver-Fehler durchlaufen!
